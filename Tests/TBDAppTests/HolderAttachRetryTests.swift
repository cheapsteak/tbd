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

    // `nonisolated`: the fake pty below reads it off the main actor.
    nonisolated private static let generation: UInt64 = 5

    /// Answers each `attach` and `ready` from a script indexed by call number,
    /// and logs every RPC in order.
    private final class ScriptedAttach: HolderAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var attachCount = 0
        private var readyCount = 0
        private let attachScript: @Sendable (Int) throws -> HolderAttachment
        private let readyScript: @Sendable (Int) throws -> Void

        init(
            attach: @escaping @Sendable (Int) throws -> HolderAttachment,
            ready: @escaping @Sendable (Int) throws -> Void = { _ in }
        ) {
            attachScript = attach
            readyScript = ready
        }

        var events: [String] { lock.withLock { log } }
        var attaches: Int { lock.withLock { attachCount } }

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment {
            let call = lock.withLock {
                log.append("attach")
                attachCount += 1
                return attachCount - 1
            }
            return try attachScript(call)
        }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            let call = lock.withLock {
                log.append("ready")
                readyCount += 1
                return readyCount - 1
            }
            try readyScript(call)
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {
            lock.withLock { log.append("detach") }
        }
    }

    /// One `socketpair` standing in for a vended pty: `vended` goes to the
    /// panel, whose reader owns and closes it; `far` stays here, where a
    /// `read` returning 0 means the panel has let go of it.
    private final class FakePTY {
        let vended: Int32
        let far: Int32

        init() {
            var pair: [Int32] = [-1, -1]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            vended = pair[0]
            far = pair[1]
            // Close-on-exec at creation, for `HolderDetachHandbackTests`'
            // reason: a sibling suite's child spawned before the attach's own
            // `fcntl` would otherwise inherit this session for the whole run.
            for fd in [vended, far] {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            }
        }

        /// Whether every copy of `vended` in this process is closed.
        var vendedIsClosed: Bool {
            var byte: UInt8 = 0
            return Darwin.read(far, &byte, 1) == 0
        }

        func closeFar() { Darwin.close(far) }

        func attachment() -> HolderAttachment {
            HolderAttachment(
                ptyFD: vended, generation: HolderAttachRetryTests.generation,
                snapshotPreamble: Data())
        }
    }

    @MainActor
    private struct Fixture {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let stub: ScriptedAttach
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
        clock: any Clock<Duration>, stub: ScriptedAttach,
        delays: [Duration] = HolderAttachRetry.delays
    ) -> Fixture {
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        state.terminals[worktreeID] = [Terminal(
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
        let pty = FakePTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment()
        let stub = ScriptedAttach(attach: { call in
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
        let stub = ScriptedAttach(attach: { _ in
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
        let stub = ScriptedAttach(attach: { _ in
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
        let first = FakePTY()
        let second = FakePTY()
        defer { first.closeFar(); second.closeFar() }
        let firstAttachment = first.attachment()
        let secondAttachment = second.attachment()
        let stub = ScriptedAttach(
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

    // MARK: - Stopping

    @Test("a teardown during the backoff ends the retries silently")
    func teardownDuringBackoffStops() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedAttach(attach: { _ in
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
    @Test("a flicker of the daemon connection during the backoff does not stop the retries")
    func aConnectionFlickerDoesNotStopTheRetries() async throws {
        let pty = FakePTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment()
        let stub = ScriptedAttach(attach: { call in
            if call == 0 { throw DaemonClientError.connectionFailed("refused") }
            return attachment
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        fixture.state.isConnected = false
        fixture.state.isConnected = true
        await clock.advance(by: HolderAttachRetry.delays[0])
        await attaching.value

        #expect(stub.events == ["attach", "attach", "ready"],
                "the retry must survive a connection flicker: \(stub.events)")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage))
    }

    @Test("a cancelled backoff ends the retries at the placard")
    func aCancelledBackoffStops() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedAttach(attach: { _ in
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
        #expect(fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "the panel is still up and still unattached, so it must say so")
        #expect(fixture.retryOffers.value == 1)
    }
}
