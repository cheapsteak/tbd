import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// The single-instance gate's one authorised exception, and the retirement it
/// performs.
///
/// `.clockDriven` is a hang-catcher: the retire tests drive a virtual clock,
/// and a sleep nobody advances would otherwise stop the whole run silently.
@Suite("Daemon handover", .clockDriven)
struct DaemonHandoverTests {

    /// A `sendSignal`/`isLive` pair a test can both program and read back.
    ///
    /// `isLive` answers `true` until it has been asked `aliveForChecks` times,
    /// which is how "the predecessor exits partway through the wait" is
    /// expressed without a second process.
    private final class Predecessor: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private var signals: [Int32] = []
        private let aliveForChecks: Int

        init(aliveForChecks: Int) {
            self.aliveForChecks = aliveForChecks
        }

        var sent: [Int32] {
            lock.lock(); defer { lock.unlock() }
            return signals
        }

        @Sendable func isLive(_ pid: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            checks += 1
            return checks <= aliveForChecks
        }

        @Sendable func send(_ pid: pid_t, _ signal: Int32) {
            lock.lock(); defer { lock.unlock() }
            signals.append(signal)
        }
    }

    // MARK: - The decision

    @Test("a stale pid file starts normally")
    func noLiveDaemonIsNormal() {
        #expect(
            HandoverDecision.decide(
                pidFileContents: 4242, handoverEnv: "4242", isLiveDaemon: { _ in false })
                == .normal)
        #expect(
            HandoverDecision.decide(
                pidFileContents: nil, handoverEnv: "4242", isLiveDaemon: { _ in true })
                == .normal)
    }

    @Test("the daemon we were sent to replace is taken over")
    func matchingHandoverPIDTakesOver() {
        #expect(
            HandoverDecision.decide(
                pidFileContents: 4242, handoverEnv: "4242", isLiveDaemon: { $0 == 4242 })
                == .takeOver(predecessor: 4242))
        // Whitespace survives a shell export round-trip; a trailing newline
        // must not turn a handover into a refusal.
        #expect(
            HandoverDecision.decide(
                pidFileContents: 4242, handoverEnv: " 4242\n", isLiveDaemon: { $0 == 4242 })
                == .takeOver(predecessor: 4242))
    }

    /// Everything else about a live daemon is today's behavior: exit. An
    /// out-of-date or mistyped variable must never take over a daemon it was
    /// not aimed at.
    @Test("any other live daemon is refused")
    func otherLiveDaemonIsRefused() {
        let live: (pid_t) -> Bool = { _ in true }
        #expect(
            HandoverDecision.decide(pidFileContents: 4242, handoverEnv: nil, isLiveDaemon: live)
                == .refuse(existing: 4242))
        #expect(
            HandoverDecision.decide(pidFileContents: 4242, handoverEnv: "99", isLiveDaemon: live)
                == .refuse(existing: 4242))
        #expect(
            HandoverDecision.decide(pidFileContents: 4242, handoverEnv: "", isLiveDaemon: live)
                == .refuse(existing: 4242))
        #expect(
            HandoverDecision.decide(pidFileContents: 4242, handoverEnv: "nonsense", isLiveDaemon: live)
                == .refuse(existing: 4242))
    }

    /// `scripts/update.sh` always exports the variable and exports `0` when no
    /// daemon is running, so `0` means "nobody to hand over from" rather than a
    /// malformed value. It must behave exactly as an unset variable does: the
    /// ordinary gate, which starts when the pid file is free and refuses when a
    /// live daemon owns it.
    @Test("the script's no-daemon sentinel is an ordinary start")
    func zeroMeansNoPredecessor() {
        let sentinels: [String?] = ["0", " 0\n", "-1", "", "   ", "nonsense", "12.5", nil]
        for sentinel in sentinels {
            #expect(
                HandoverDecision.decide(
                    pidFileContents: nil, handoverEnv: sentinel, isLiveDaemon: { _ in true })
                    == .normal,
                "a free pid file must start normally for handover value \(sentinel ?? "nil")")
            #expect(
                HandoverDecision.decide(
                    pidFileContents: 4242, handoverEnv: sentinel, isLiveDaemon: { _ in true })
                    == .refuse(existing: 4242),
                "a live daemon must still be refused for handover value \(sentinel ?? "nil")")
        }
        #expect(HandoverDecision.requestedPredecessor("0") == nil)
        #expect(HandoverDecision.requestedPredecessor("4242") == 4242)
    }

    /// A handover aimed at a daemon that died before the successor launched.
    /// `PIDFile.cleanupIfStale` has already removed the stale file by the time
    /// the gate runs, so this is an ordinary start — not a take-over of a
    /// process that is no longer there.
    @Test("a handover pid that is no longer a live daemon starts normally")
    func deadPredecessorStartsNormally() {
        #expect(
            HandoverDecision.decide(
                pidFileContents: nil, handoverEnv: "4242", isLiveDaemon: { _ in false })
                == .normal)
        // Belt and braces: even if the stale file survived cleanup, a pid that
        // is not a live daemon cannot be taken over.
        #expect(
            HandoverDecision.decide(
                pidFileContents: 4242, handoverEnv: "4242", isLiveDaemon: { _ in false })
                == .normal)
    }

    // MARK: - The retirement

    @Test("a predecessor that is already gone is not signalled")
    func alreadyGonePredecessorIsNotSignalled() async {
        let predecessor = Predecessor(aliveForChecks: 0)
        let handover = DaemonHandover(
            sendSignal: predecessor.send, isLive: predecessor.isLive,
            clock: EventDrivenTestClock())
        #expect(await handover.retire(predecessor: 4242) == .alreadyGone)
        #expect(predecessor.sent.isEmpty)
    }

    @Test("a predecessor that exits inside the budget needs only SIGTERM")
    func politeExitStopsAtSIGTERM() async throws {
        // Alive for the entry check, gone by the first poll.
        let predecessor = Predecessor(aliveForChecks: 1)
        let clock = EventDrivenTestClock()
        let handover = DaemonHandover(
            termBudget: .milliseconds(300), killBudget: .milliseconds(100),
            pollInterval: .milliseconds(100),
            sendSignal: predecessor.send, isLive: predecessor.isLive, clock: clock)

        let retirement = Task { await handover.retire(predecessor: 4242) }
        try await clock.requireAdvanceWhenArmed(by: .milliseconds(100))

        #expect(await retirement.value == .exitedAfterTerm)
        #expect(predecessor.sent == [SIGTERM])
    }

    /// The escalation. Budgets are instance properties precisely so this costs
    /// three virtual polls instead of three hundred real ones.
    @Test("a predecessor that never exits is SIGKILLed and then given up on")
    func stuckPredecessorEscalatesToSIGKILL() async throws {
        let predecessor = Predecessor(aliveForChecks: .max)
        let clock = EventDrivenTestClock()
        let handover = DaemonHandover(
            termBudget: .milliseconds(200), killBudget: .milliseconds(100),
            pollInterval: .milliseconds(100),
            sendSignal: predecessor.send, isLive: predecessor.isLive, clock: clock)

        let retirement = Task { await handover.retire(predecessor: 4242) }
        // Two polls inside the SIGTERM budget, then one inside the SIGKILL one.
        for _ in 0..<3 {
            try await clock.requireAdvanceWhenArmed(by: .milliseconds(100))
        }

        #expect(await retirement.value == .stillAlive)
        #expect(predecessor.sent == [SIGTERM, SIGKILL])
    }

    @Test("a predecessor that only dies to SIGKILL reports that")
    func stubbornPredecessorExitsAfterSIGKILL() async throws {
        // Entry check + two SIGTERM polls alive, gone on the first SIGKILL poll.
        let predecessor = Predecessor(aliveForChecks: 3)
        let clock = EventDrivenTestClock()
        let handover = DaemonHandover(
            termBudget: .milliseconds(200), killBudget: .milliseconds(100),
            pollInterval: .milliseconds(100),
            sendSignal: predecessor.send, isLive: predecessor.isLive, clock: clock)

        let retirement = Task { await handover.retire(predecessor: 4242) }
        for _ in 0..<3 {
            try await clock.requireAdvanceWhenArmed(by: .milliseconds(100))
        }

        #expect(await retirement.value == .exitedAfterKill)
        #expect(predecessor.sent == [SIGTERM, SIGKILL])
    }

    // MARK: - Budget arithmetic

    @Test("a budget floors to whole polls and never to zero")
    func pollCountFloorsAtOne() {
        #expect(DaemonHandover.pollCount(budget: .seconds(30), interval: .milliseconds(100)) == 300)
        #expect(DaemonHandover.pollCount(budget: .milliseconds(250), interval: .milliseconds(100)) == 2)
        #expect(DaemonHandover.pollCount(budget: .zero, interval: .milliseconds(100)) == 1)
        #expect(DaemonHandover.pollCount(budget: .seconds(1), interval: .zero) == 1)
    }
}
