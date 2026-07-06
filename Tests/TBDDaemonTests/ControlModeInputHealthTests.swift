import Foundation
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
        private var _events: [(worktreeID: UUID, paneID: String, healthy: Bool)] = []
        func record(_ worktreeID: UUID, _ paneID: String, _ healthy: Bool) {
            lock.lock(); _events.append((worktreeID, paneID, healthy)); lock.unlock()
        }
        var events: [(worktreeID: UUID, paneID: String, healthy: Bool)] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
    }

    /// Thread-safe recorder of stream writes.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    private final class ClientHolder: @unchecked Sendable {
        weak var client: TmuxControlCommandClient?
    }

    /// Poll until `recorder` has at least `count` health events (15 s deadline +
    /// post-deadline re-check; see ControlModeInputRouterTests.waitForWrites for
    /// why the budget is generous under parallel-suite load).
    private func waitForEvents(_ recorder: HealthRecorder, count: Int,
                               timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.events.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard recorder.events.count < count else { return }
        throw HealthTestError.timedOut(got: recorder.events.count, want: count)
    }

    private func waitForWrites(_ recorder: Recorder, count: Int,
                               timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if recorder.writes.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard recorder.writes.count < count else { return }
        throw HealthTestError.timedOut(got: recorder.writes.count, want: count)
    }

    /// A router whose client replies to every command: `%error` when
    /// `shouldFail(commandText)` says so, `%end` otherwise. Replies are fed
    /// back one per command in FIFO order, so completion order matches write
    /// order and health transitions are deterministic.
    private func makeRouter(shouldFail: @escaping @Sendable (String) -> Bool)
        -> (ControlModeInputRouter, Recorder, HealthRecorder) {
        let recorder = Recorder()
        let health = HealthRecorder()
        let holder = ClientHolder()
        let client = TmuxControlCommandClient(
            writeLine: { line in
                recorder.record(line)
                let commands = line.split(separator: "\n", omittingEmptySubsequences: false)
                Task {
                    for command in commands {
                        if shouldFail(String(command)) {
                            await holder.client?.handle(
                                .commandFailed(number: 0, fromClient: true, lines: ["no pane"]))
                        } else {
                            await holder.client?.handle(
                                .commandSucceeded(number: 0, fromClient: true, lines: []))
                        }
                    }
                }
            },
            onFatalError: {})
        holder.client = client
        let router = ControlModeInputRouter(
            commandProvider: { server in server == "srv" ? client : nil },
            onHealthChange: { worktreeID, paneID, healthy in
                health.record(worktreeID, paneID, healthy)
            })
        return (router, recorder, health)
    }

    /// The sentinel byte 0xFF marks a keystroke the fake client should ACCEPT;
    /// everything else fails. Lets one test drive fail → success deterministically.
    private static let failUnlessFF: @Sendable (String) -> Bool = { command in
        command.hasPrefix("send-keys") && !command.hasSuffix(" ff")
    }

    @Test("repeated send-keys failures fire exactly ONE failing transition")
    func repeatedFailuresFireOnce() async throws {
        let worktreeID = UUID()
        let (router, _, health) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        // Three failing keystrokes, then one succeeding sentinel. The sentinel's
        // completion is FIFO-behind all three failures, so once the recovery
        // event lands we KNOW all three failures were processed.
        for _ in 0..<3 { router.enqueue(header: header, bytes: Data([0x41])) }
        router.enqueue(header: header, bytes: Data([0xff]))

        try await waitForEvents(health, count: 2)
        let events = health.events
        #expect(events.count == 2)
        #expect(events[0].healthy == false)
        #expect(events[0].worktreeID == worktreeID)
        #expect(events[0].paneID == "%0")
        #expect(events[1].healthy == true)
        router.shutdown()
    }

    @Test("fail then success fires one failing and one recovery transition")
    func failThenRecoveryFiresOnce() async throws {
        let worktreeID = UUID()
        let (router, _, health) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails
        router.enqueue(header: header, bytes: Data([0xff]))   // succeeds
        router.enqueue(header: header, bytes: Data([0xff]))   // steady healthy: no event

        try await waitForEvents(health, count: 2)
        // Give the third completion time to land, then confirm no third event.
        try await Task.sleep(for: .milliseconds(50))
        #expect(health.events.map(\.healthy) == [false, true])
        router.shutdown()
    }

    @Test("successful deliveries alone never fire a transition")
    func successOnlyIsSilent() async throws {
        let worktreeID = UUID()
        let (router, recorder, health) = makeRouter(shouldFail: { _ in false })
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        for i in 0..<5 { router.enqueue(header: header, bytes: Data([UInt8(i)])) }

        try await waitForWrites(recorder, count: 5)
        try await Task.sleep(for: .milliseconds(50))   // let completions drain
        #expect(health.events.isEmpty)
        router.shutdown()
    }

    @Test("input for an unregistered pane does NOT trip failing health")
    func unregisteredPaneDropIsNotFailure() async throws {
        let worktreeID = UUID()
        let (router, recorder, health) = makeRouter(shouldFail: { _ in false })
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        // Unregistered pane first; a registered success after it proves the
        // drop was processed by the time we assert.
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%9"),
                       bytes: Data([0x41]))
        router.enqueue(header: SidecarInputHeader(worktreeID: worktreeID, paneID: "%0"),
                       bytes: Data([0x42]))

        try await waitForWrites(recorder, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(health.events.isEmpty)
        router.shutdown()
    }

    @Test("a missing command client (server down) trips failing health")
    func missingCommandClientTripsFailing() async throws {
        let health = HealthRecorder()
        let router = ControlModeInputRouter(
            commandProvider: { _ in nil },   // server connection is down
            onHealthChange: { worktreeID, paneID, healthy in
                health.record(worktreeID, paneID, healthy)
            })
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))
        router.enqueue(header: header, bytes: Data([0x42]))   // steady failing: no 2nd event

        try await waitForEvents(health, count: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(health.events.map(\.healthy) == [false])
        router.shutdown()
    }

    @Test("a paste failure trips failing; the next successful keystroke recovers")
    func pasteFailureTripsFailing() async throws {
        // paste-buffer replies %error; everything else (load-buffer,
        // delete-buffer, send-keys) succeeds — same shape as the router
        // suite's pasteFailureDoesNotStall.
        let (router, _, health) = makeRouter(shouldFail: { $0.hasPrefix("paste-buffer") })
        let worktreeID = UUID()
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueuePaste(header: header, bytes: Data(repeating: 0x50, count: 1024))
        router.enqueue(header: header, bytes: Data([0x5a]))

        try await waitForEvents(health, count: 2)
        #expect(health.events.map(\.healthy) == [false, true])
        router.shutdown()
    }

    @Test("unregister clears health state: a re-attach that fails fires failing again")
    func unregisterResetsHealthState() async throws {
        let worktreeID = UUID()
        let (router, _, health) = makeRouter(shouldFail: Self.failUnlessFF)
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")
        let header = SidecarInputHeader(worktreeID: worktreeID, paneID: "%0")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 1
        try await waitForEvents(health, count: 1)

        // Detach then re-attach: state must reset WITHOUT a recovery event.
        router.unregister(worktreeID: worktreeID, paneID: "%0")
        router.register(worktreeID: worktreeID, paneID: "%0", server: "srv")

        router.enqueue(header: header, bytes: Data([0x41]))   // fails → event 2
        try await waitForEvents(health, count: 2)
        #expect(health.events.map(\.healthy) == [false, false])
        router.shutdown()
    }
}

private enum HealthTestError: Error { case timedOut(got: Int, want: Int) }
