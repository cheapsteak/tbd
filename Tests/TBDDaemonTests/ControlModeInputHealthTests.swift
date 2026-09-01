import Foundation
import TestSupport
import Testing
import TBDShared
@testable import TBDDaemonLib

/// Edge-triggered input-delivery health tests for `ControlModeInputRouter`
/// (#318 polish ruling): a pane transitioning into failing fires ONE
/// notification, transitioning back to healthy fires ONE notification, and
/// steady-state failure/success fires nothing — never per-keystroke spam.
///
/// Same harness style as `ControlModeInputRouterTests`: no tmux, a real
/// `TmuxControlCommandClient` whose `writeLine` records writes and feeds
/// replies back (success or `%error` chosen per command), and a fake
/// `commandProvider`.
@Suite("ControlModeInputHealth")
struct ControlModeInputHealthTests {

    /// Thread-safe recorder of health transitions in call order.
    private final class HealthRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(worktreeID: UUID, paneID: String, healthy: Bool, generation: UInt64?)] = []
        func record(_ worktreeID: UUID, _ paneID: String, _ healthy: Bool, _ generation: UInt64?) {
            lock.lock(); _events.append((worktreeID, paneID, healthy, generation)); lock.unlock()
        }
        var events: [(worktreeID: UUID, paneID: String, healthy: Bool, generation: UInt64?)] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
    }

    /// Poll until `recorder` has at least `count` health events (shared
    /// `waitFor`, which keeps the post-deadline re-check this suite needed
    /// under parallel-suite load). Reports the events actually observed: the
    /// bare count this waits on says nothing about what arrived, and it is the
    /// finding when it times out.
    private func waitForEvents(_ recorder: HealthRecorder, count: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try await waitFor("\(count) health events",
                          observed: { Self.describe(recorder.events) },
                          sourceLocation: sourceLocation) {
            recorder.events.count >= count
        }
    }

    private func waitForWrites(_ recorder: LineRecorder, count: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try await waitFor("\(count) stream writes",
                          observed: { "\(recorder.writes.count): \(recorder.writes)" },
                          sourceLocation: sourceLocation) {
            recorder.writes.count >= count
        }
    }

    /// Renders health events for a timeout diagnostic — `1: [%0 failing gen=42]`.
    private static func describe(
        _ events: [(worktreeID: UUID, paneID: String, healthy: Bool, generation: UInt64?)]
    ) -> String {
        let rendered = events.map { event in
            "\(event.paneID) \(event.healthy ? "healthy" : "failing") "
                + "gen=\(event.generation.map(String.init) ?? "nil")"
        }
        return "\(events.count): [\(rendered.joined(separator: ", "))]"
    }

    /// A router whose client replies to every command: `%error` when
    /// `shouldFail(commandText)` says so, `%end` otherwise.
    ///
    /// The replies go through a shared `ReplyFeed`, whose single long-lived
    /// consumer makes completion order equal write order **by construction** —
    /// the invariant the correlator's order-based matching depends on and that
    /// production gets from `TmuxControlSupervisor`'s one drain loop. The
    /// per-write `Task { … }` this replaced only *looked* FIFO on an idle box;
    /// under load its verdicts landed on the wrong commands and stranded these
    /// edge-triggered assertions (#494). See `ReplyFeed` for the full account.
    ///
    /// The returned feed is also the quiescence signal: `waitForDeliveries(n)`
    /// proves the first `n` verdicts were recorded, which a fixed settle cannot.
    private func makeRouter(shouldFail: @escaping @Sendable (String) -> Bool)
        -> (ControlModeInputRouter, LineRecorder, HealthRecorder, ReplyFeed) {
        let health = HealthRecorder()
        let (client, recorder, feed) = makeRespondingClient(shouldFail: shouldFail)
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            onHealthChange: { worktreeID, paneID, healthy, generation in
                health.record(worktreeID, paneID, healthy, generation)
            })
        return (router, recorder, health, feed)
    }

    /// The sentinel byte 0xFF marks a keystroke the fake client should ACCEPT;
    /// everything else fails. Lets one test drive fail → success deterministically.
    private static let failUnlessFF: @Sendable (String) -> Bool = { command in
        command.hasPrefix("send-keys") && !command.hasSuffix(" ff")
    }

    @Test("repeated send-keys failures fire exactly ONE failing transition")
    func repeatedFailuresFireOnce() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        // Three failing keystrokes, then one succeeding sentinel. The sentinel's
        // completion is FIFO-behind all three failures, so once the recovery
        // event lands we KNOW all three failures were processed.
        for _ in 0..<3 { router.enqueue(header: header, bytes: Data([0x41])) }
        router.enqueue(header: header, bytes: Data([0xff]))

        try #require(await waitForEvents(health, count: 2))
        try #require(await feed.waitForDeliveries(4))
        let events = health.events
        #expect(events.count == 2)
        #expect(events[0].healthy == false)
        #expect(events[0].worktreeID == worktreeID)
        #expect(events[0].paneID == "%0")
        #expect(events[1].healthy == true)
        router.shutdown()
        await feed.finish()
    }

    @Test("fail then success fires one failing and one recovery transition")
    func failThenRecoveryFiresOnce() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails
        router.enqueue(header: header, bytes: Data([0xff]))   // succeeds
        router.enqueue(header: header, bytes: Data([0xff]))   // steady healthy: no event

        try #require(await waitForEvents(health, count: 2))
        // The third verdict is RECORDED, not merely waited out: `reportDelivery`
        // runs inside `client.handle`, so three deliveries means the steady
        // success was processed and stayed silent.
        try #require(await feed.waitForDeliveries(3))
        #expect(health.events.map(\.healthy) == [false, true])
        router.shutdown()
        await feed.finish()
    }

    @Test("successful deliveries alone never fire a transition")
    func successOnlyIsSilent() async throws {
        let worktreeID = UUID()
        let (router, recorder, health, feed) = makeRouter(shouldFail: { _ in false })
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        for i in 0..<5 { router.enqueue(header: header, bytes: Data([UInt8(i)])) }

        try #require(await waitForWrites(recorder, count: 5))
        try #require(await feed.waitForDeliveries(5))   // all five verdicts recorded
        #expect(health.events.isEmpty)
        router.shutdown()
        await feed.finish()
    }

    @Test("input for an unregistered pane does NOT trip failing health")
    func unregisteredPaneDropIsNotFailure() async throws {
        let worktreeID = UUID()
        let (router, recorder, health, feed) = makeRouter(shouldFail: { _ in false })
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        // Unregistered pane first; a registered success after it proves the
        // drop was processed by the time we assert — the router's consumer is
        // strictly sequential, so the second item's verdict cannot be recorded
        // before the first item was handled.
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%9"),
                       bytes: Data([0x41]))
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%0"),
                       bytes: Data([0x42]))

        try #require(await waitForWrites(recorder, count: 1))
        try #require(await feed.waitForDeliveries(1))
        #expect(health.events.isEmpty)
        router.shutdown()
        await feed.finish()
    }

    @Test("a missing command client (server down) trips failing health")
    func missingCommandClientTripsFailing() async throws {
        let health = HealthRecorder()
        // There is no client here, so no reply feed either; the lookups
        // themselves are the quiescence signal. The router's consumer is
        // strictly sequential, so the Nth lookup starting proves item N-1 was
        // fully delivered — including its `reportDelivery`.
        let lookups = LineRecorder()
        let router = ControlModeInputRouter(
            commandProvider: { server in   // server connection is down
                lookups.record(server)
                return nil
            },
            onHealthChange: { worktreeID, paneID, healthy, generation in
                health.record(worktreeID, paneID, healthy, generation)
            })
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))
        router.enqueue(header: header, bytes: Data([0x42]))   // steady failing: no 2nd event
        router.enqueue(header: header, bytes: Data([0x43]))   // probe: its lookup fences the two above

        try #require(await waitForEvents(health, count: 1))
        try #require(await waitFor("3 command-client lookups",
                                   observed: { "\(lookups.writes.count)" }) {
            lookups.writes.count >= 3
        })
        #expect(health.events.map(\.healthy) == [false])
        router.shutdown()
    }

    @Test("a paste failure trips failing; the next successful keystroke recovers")
    func pasteFailureTripsFailing() async throws {
        // paste-buffer replies %error; everything else (load-buffer,
        // delete-buffer, send-keys) succeeds — same shape as the router
        // suite's pasteFailureDoesNotStall.
        let (router, _, health, feed) = makeRouter(shouldFail: { $0.hasPrefix("paste-buffer") })
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 1024))
        router.enqueue(header: header, bytes: Data([0x5a]))

        try #require(await waitForEvents(health, count: 2))
        #expect(health.events.map(\.healthy) == [false, true])
        router.shutdown()
        await feed.finish()
    }

    @Test("unregister clears health state: a re-attach that fails fires failing again")
    func unregisterResetsHealthState() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 1
        try #require(await waitForEvents(health, count: 1))

        // Detach then re-attach: state must reset WITHOUT a recovery event.
        router.unregister(worktreeID: worktreeID, paneID: "%0")
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 2
        try #require(await waitForEvents(health, count: 2))
        #expect(health.events.map(\.healthy) == [false, false])
        router.shutdown()
        await feed.finish()
    }

    @Test("health events carry the attach generation registered with the route (R6-M7)")
    func healthEventsCarryRegisteredGeneration() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv", generation: 42)
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → failing event
        router.enqueue(header: header, bytes: Data([0xff]))   // succeeds → recovery event

        try #require(await waitForEvents(health, count: 2))
        // Both edges are stamped with the registered attach generation, so
        // the app can refuse a stale attach's failure against a fresh attach.
        #expect(health.events.map(\.generation) == [42, 42])

        // A re-attach re-registers with a NEWER generation: subsequent
        // events carry it — never the stale one.
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv", generation: 43)
        router.enqueue(header: header, bytes: Data([0x41]))   // fails again → event 3
        try #require(await waitForEvents(health, count: 3))
        #expect(health.events.last?.generation == 43)
        router.shutdown()
        await feed.finish()
    }

    @Test("a route registered without a generation stamps nil (back-compat)")
    func generationlessRouteStampsNil() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))
        try #require(await waitForEvents(health, count: 1))
        #expect(health.events.map(\.generation) == [nil])
        router.shutdown()
        await feed.finish()
    }

    @Test("register alone resets health state: a lost detach cannot leak a stale failing flag into a re-attach")
    func registerResetsHealthStateWithoutUnregister() async throws {
        let worktreeID = UUID()
        let (router, _, health, feed) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 1
        try #require(await waitForEvents(health, count: 1))

        // Re-attach WITHOUT the detach's unregister (the pane.detach RPC was
        // lost): the fresh attach must still start from a healthy baseline —
        // silently, no recovery event — so its first failure re-fires.
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 2
        try #require(await waitForEvents(health, count: 2))
        #expect(health.events.map(\.healthy) == [false, false])
        router.shutdown()
        await feed.finish()
    }
}
