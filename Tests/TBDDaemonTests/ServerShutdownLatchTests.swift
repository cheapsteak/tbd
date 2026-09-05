import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// A daemon shutdown must survive being asked for twice.
//
// SIGTERM and SIGINT each fire an independent, undeduplicated
// `Task { await daemon.stop() }` in main.swift, and `Daemon.stop()` is not
// itself deduplicated, so an escalating supervisor runs the whole teardown
// twice. Every NIO-backed server in that teardown wedges on a second run —
// `channel.close()` off the event loop submits work to a loop whose group has
// shut down, and such a loop discards submitted work rather than running it, so
// the close promise is never fulfilled. A wedged teardown never reaches its
// `exit(0)`.
@Suite("Repeat server shutdowns")
struct ServerShutdownLatchTests {

    /// Throwaway RPCRouter: in-memory DB + dryRun tmux, so no real tmux server
    /// is contacted and nothing under ~/tbd is touched.
    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    @Test("the latch runs its body once, and every caller waits for that one run")
    func latchRunsItsBodyOnceAndEveryCallerWaits() async throws {
        // Nothing this test waits on is scheduled on the cooperative pool.
        //
        // It used to be: the callers were `Task.detached` and the latch's own
        // run is an unstructured `Task`, which SE-0417 keeps off any executor
        // preference its creator carries. Both land on the pool, and a
        // detached task carries no priority, so in a parallel pass that
        // admits ~5,000 tests against a 3-thread runner they queue behind
        // every higher-priority test task for as long as the pass keeps the
        // pool busy. CI observed exactly that: 0 of 8 callers back after
        // 90 s, while this test's own polling loop — a test-priority task —
        // kept running the whole time. No bound fixes queueing that never
        // drains, so the pool is taken out of the picture instead: the
        // callers start with `gateHoldingTask`, and the latch is built with
        // the same `GateExecutor` so its run lands on threads these tests own
        // too. `latchRunsItsBodyOnTheInjectedExecutor` pins that the seam
        // actually carries the run.
        //
        // With the run on a thread the test owns, the body can be *held*
        // rather than merely slowed: it blocks on a gate the test releases
        // once every caller has arrived, so a caller that failed to wait for
        // the run has the whole hold to return early in, not a window of a
        // few yields whose width depends on the machine.
        let latch = ShutdownLatch(executor: GateExecutor.shared)
        let runs = ShutdownCounter()
        let bodyThread = ThreadNameBox()
        let arrived = ShutdownCounter()
        let returned = ShutdownCounter()
        let returnedBeforeTheBodyFinished = ShutdownCounter()
        let bodyFinished = ShutdownFlag()
        let releaseTheBody = DispatchSemaphore(value: 0)
        let callers = 8

        for _ in 0..<callers {
            _ = gateHoldingTask {
                arrived.increment()
                await latch.run {
                    runs.increment()
                    bodyThread.recordCurrentThread()
                    releaseTheBody.waitForGate("the test to release the shutdown body")
                    bodyFinished.set()
                }
                if !bodyFinished.isSet { returnedBeforeTheBodyFinished.increment() }
                returned.increment()
            }
        }

        try await waitFor(
            "all \(callers) callers to reach the latch while its run is held",
            observed: { "\(arrived.count) of \(callers) arrived, \(runs.count) runs" }
        ) { arrived.count == callers && runs.count == 1 }
        // One signal per caller rather than one: a latch that wrongly ran the
        // body more than once would otherwise park its extra runs on the gate
        // until `TestGate.deadline`, after this test has already reported. Over-
        // signalling costs nothing, and the duplicate run is still reported —
        // by the `runs` expectation below, which is the one that names it.
        for _ in 0..<callers { releaseTheBody.signal() }

        try await waitFor(
            "all \(callers) latch callers to return",
            observed: { "\(returned.count) of \(callers) returned" }
        ) { returned.count == callers }
        #expect(runs.count == 1, "the latch ran its body \(runs.count) times; exactly one may")
        #expect(
            returnedBeforeTheBodyFinished.count == 0,
            "\(returnedBeforeTheBodyFinished.count) callers returned before the shutdown had finished"
        )
        // Self-pinned rather than remembered: the gate above blocks whatever
        // thread runs the body, and only the `executor:` argument keeps that
        // off the cooperative pool. Drop it and this is what goes red.
        #expect(
            bodyThread.name == GateExecutor.threadName,
            "the held body ran on \(bodyThread.name ?? "an unnamed thread"); it must run on a thread the tests own"
        )
    }

    @Test("a default-constructed latch runs its body once across repeat calls")
    func defaultLatchRunsItsBodyOnce() async {
        // The production configuration — `SocketServer` and `HTTPServer` both
        // build their latch with no executor — keeps its once-only coverage.
        // Sequential rather than concurrent callers, because this run does go
        // to the cooperative pool: it is one task at the test's own priority,
        // which is the same exposure every other test in the pass has, and not
        // eight detached callers at default priority.
        let latch = ShutdownLatch()
        let runs = ShutdownCounter()
        await latch.run { runs.increment() }
        await latch.run { runs.increment() }
        #expect(runs.count == 1, "the latch ran its body \(runs.count) times; exactly one may")
    }

    @Test("the latch runs its body on the injected executor")
    func latchRunsItsBodyOnTheInjectedExecutor() async {
        // The seam the test above rests on. `gateHoldingTask` alone does not
        // reach the run — `BoundedGateWaitTests` pins that an unstructured
        // `Task` drops the preference — so the latch has to carry the executor
        // itself, and this is the check that it does. If this fails, the test
        // above is back to racing the cooperative pool, whatever its bound.
        let latch = ShutdownLatch(executor: GateExecutor.shared)
        let bodyThread = await gateHoldingTask { () -> String? in
            let box = ThreadNameBox()
            await latch.run { box.recordCurrentThread() }
            return box.name
        }.value
        #expect(
            bodyThread == GateExecutor.threadName,
            "the latch's run landed on \(bodyThread ?? "an unnamed thread"), not the injected executor"
        )
    }

    @Test("a second shutdown of the HTTP server returns")
    func repeatHTTPServerStopReturns() async throws {
        // The sibling of `SocketServer` in the same teardown, and the one a
        // fixed `SocketServer` would otherwise hand the hang straight on to:
        // `Daemon.stop()` stops the socket server and then this one.
        let portFilePath = "/tmp/tbd-httpshutdown-\(UUID().uuidString.prefix(8)).port"
        defer { unlink(portFilePath) }

        let server = HTTPServer(router: try makeRouter(), portFilePath: portFilePath)
        try await server.start()
        await server.stop()

        let returned = ShutdownCounter()
        // Started as a separate task and waited on with a deadline rather
        // than awaited directly: the failure under test is a shutdown that
        // never returns, and awaiting it would wedge the whole run instead of
        // reporting it. `gateHoldingTask` keeps the caller off the cooperative
        // pool; the server's own latch has no executor injected, but its run
        // already finished with the first `stop()`, so this second call awaits
        // a completed task and never needs the pool to make progress.
        _ = gateHoldingTask {
            await server.stop()
            returned.increment()
        }
        try await waitFor(
            "the second stop() to return",
            observed: { "\(returned.count) of 1 returned" }
        ) { returned.count == 1 }
    }
}

/// Counts callers or runs across threads.
private final class ShutdownCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Records the thread the latched body ran on, from inside that body.
///
/// The read is synchronous on purpose: `Thread.current` is unavailable across
/// a suspension point precisely because the answer can change there, and
/// which thread the body starts on is the thing under test.
private final class ThreadNameBox: @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    func recordCurrentThread() {
        lock.lock()
        defer { lock.unlock() }
        value = Thread.current.name
    }

    var name: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Set once by the latched body, read by every caller as it returns.
private final class ShutdownFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
