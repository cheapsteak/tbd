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
        let latch = ShutdownLatch()
        let runs = ShutdownCounter()
        let returned = ShutdownCounter()
        let returnedBeforeTheBodyFinished = ShutdownCounter()
        let bodyFinished = ShutdownFlag()
        let callers = 8

        for _ in 0..<callers {
            Task.detached {
                await latch.run {
                    runs.increment()
                    // Suspends, so a caller that failed to wait for the run
                    // would return while this is still in flight. One yield
                    // would already open that window; a few widen it without
                    // making the test's cost depend on how loaded the machine
                    // is. Every `Task.yield()` is a full trip to the back of
                    // the process-wide run queue, and in the saturated pass
                    // that queue holds thousands of runnable tasks — the
                    // hundred yields this started out with took longer than
                    // the whole wait below.
                    for _ in 0..<20 { await Task.yield() }
                    bodyFinished.set()
                }
                if !bodyFinished.isSet { returnedBeforeTheBodyFinished.increment() }
                returned.increment()
            }
        }

        // `waitFor` at the repo-wide saturated-pass budget rather than a snug
        // few seconds. These callers are detached tasks, so the thing being
        // waited on is the cooperative pool getting round to them: 5,059 tests
        // share one process and a pool three threads wide on CI's runner, and
        // scheduling latency there is measured in tens of seconds. A shorter
        // bound reports queueing as a wedged latch.
        try await waitFor(
            "all \(callers) latch callers to return",
            observed: { "\(returned.count) of \(callers) returned" }
        ) { returned.count == callers }
        #expect(runs.count == 1, "the latch ran its body \(runs.count) times; exactly one may")
        #expect(
            returnedBeforeTheBodyFinished.count == 0,
            "\(returnedBeforeTheBodyFinished.count) callers returned before the shutdown had finished"
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
        // Detached and waited on with a deadline rather than awaited directly:
        // the failure under test is a shutdown that never returns, and awaiting
        // it would wedge the whole run instead of reporting it.
        Task.detached {
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
