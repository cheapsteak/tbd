import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// R5-M1: a fatal-error teardown's blocking `stop()` (up to ~2 s of SIGTERM →
/// SIGKILL escalation) must run OFF the supervisor actor — otherwise every
/// supervisor call for every worktree stalls behind one wedged connection.
@Suite("TmuxControlSupervisor teardown isolation")
struct TmuxControlSupervisorTeardownTests {

    /// Write an executable stub "tmux" that ignores its args and sleeps, so a
    /// real `TmuxControlConnection` can start (pty + process) without tmux.
    private func makeStubBinary() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-teardown-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("stub-tmux.sh").path
        try "#!/bin/sh\nexec sleep 300\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test("a slow connection stop does not block unrelated supervisor calls")
    func slowStopDoesNotBlockActor() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        // The stop seam blocks until the TEST releases it, so "teardown is
        // mid-stop" is a deterministic state, not a timing window.
        let stopStarted = EventCounter()
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                stopStarted.increment()
                // Gate ONLY the teardown under test. The test's closing
                // `stopAll()` cleanup re-enters this seam for the successor
                // connection; gating that call too would deadlock the test
                // against its own semaphore (the defer below can't run while
                // the body is awaiting stopAll).
                if stopStarted.count == 1 { stopGate.wait() }
                connection.stop()
            })
        defer { stopGate.signal() }  // never leave the stop thread parked on failure

        await supervisor.ensureConnection(serverName: "srv-slow")
        let client = try #require(await supervisor.command(server: "srv-slow"))

        // Trigger the real fatal path: a client-originated reply block with an
        // empty queue is a correlator protocol violation → onFatalError →
        // teardown. (Reachable in production from any untolerated %error too.)
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))
        #expect(await waitUntil(
            { stopStarted.count == 1 }, timeout: .seconds(15)), "teardown never reached stop()")

        // While the stop is STILL blocked, unrelated supervisor calls must
        // complete. Bounded by a generous CI-safe deadline: pre-fix, the
        // actor is wedged inside stopConnection and the call never returns.
        // Unstructured on purpose — a task blocked on a wedged actor cannot
        // be cancelled, so a task group here would hang the test forever.
        let unrelatedDone = EventCounter()
        Task.detached {
            _ = await supervisor.command(server: "srv-unrelated")
            unrelatedDone.increment()
        }
        let unrelatedCompleted = await waitUntil({ unrelatedDone.count == 1 }, timeout: .seconds(10))
        #expect(unrelatedCompleted, "supervisor actor is blocked by a mid-stop teardown")
        // Pre-fix the actor stays wedged until the gate opens — unwedge so the
        // remaining assertions (and cleanup) can run instead of hanging.
        if !unrelatedCompleted { stopGate.signal() }

        // State left the maps BEFORE stop() ran (that is what un-wedges the
        // actor above), so the eviction is observable now — but a successor
        // may NOT go live until the old stop completes (R6-M4):
        // `ensureConnection` for the same server suspends instead (covered by
        // `ensureConnectionWaitsForInFlightStop` below).
        #expect(await supervisor.command(server: "srv-slow") == nil,
                "faulted connection's client must be evicted before stop()")

        stopGate.signal()   // release the held stop; it stops the stub process
        await supervisor.ensureConnection(serverName: "srv-slow")
        #expect(await supervisor.command(server: "srv-slow") != nil,
                "a successor connection must be creatable once the stop completed")
        await supervisor.stopAll()
    }

    @Test("ensureConnection cannot race an in-flight teardown into two live connections (R6-M4)")
    func ensureConnectionWaitsForInFlightStop() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        let created = EventCounter()
        let stopStarted = EventCounter()
        let stopFinished = EventCounter()
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { server in
                created.increment()
                return TmuxControlConnection(serverName: server, tmuxBinary: stub)
            },
            stopConnection: { connection in
                stopStarted.increment()
                // Gate ONLY the teardown under test — see
                // slowStopDoesNotBlockActor for why the closing stopAll()
                // cleanup must pass through ungated.
                if stopStarted.count == 1 { stopGate.wait() }
                connection.stop()
                stopFinished.increment()
            })
        defer { stopGate.signal() }  // never leave the stop thread parked on failure

        await supervisor.ensureConnection(serverName: "srv-race")
        #expect(created.count == 1)
        let client = try #require(await supervisor.command(server: "srv-race"))

        // Fatal correlator violation → teardown; eviction runs, stop is held.
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))
        #expect(await waitUntil(
            { stopStarted.count == 1 }, timeout: .seconds(15)), "teardown never reached stop()")

        // A re-attach's ensureConnection lands while the old tmux client
        // process is still dying. It must SUSPEND: `PaneFanout.route` keys by
        // (server, paneID) only, so a successor started now would leave two
        // live -CC connections routing duplicate %output into one pane pipe.
        let ensured = EventCounter()
        Task.detached {
            await supervisor.ensureConnection(serverName: "srv-race")
            ensured.increment()
        }
        // Bounded negative check: give the racing ensureConnection ample time
        // to (incorrectly) create a successor — pre-fix `created` hits 2 here.
        try await Task.sleep(for: .milliseconds(500))
        #expect(created.count == 1,
                "no successor may be created while the old connection is still stopping")
        #expect(ensured.count == 0, "ensureConnection must still be suspended mid-stop")

        // The held stop completes → the parked ensureConnection resumes and
        // creates exactly one successor.
        stopGate.signal()
        #expect(await waitUntil({ ensured.count == 1 }, timeout: .seconds(60)),
                "ensureConnection must resume once the stop completed")
        #expect(stopFinished.count == 1)
        #expect(created.count == 2, "exactly one successor after the teardown finished")
        #expect(await supervisor.command(server: "srv-race") != nil)
        await supervisor.stopAll()
    }

    @Test("stopAll's blocking stops run off the actor: unrelated calls complete mid-stop (R8-M2)")
    func stopAllDoesNotBlockActor() async throws {
        let stub = try makeStubBinary()
        defer { try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent) }

        let stopStarted = EventCounter()
        let stopGate = DispatchSemaphore(value: 0)
        let supervisor = TmuxControlSupervisor(
            makeConnection: { TmuxControlConnection(serverName: $0, tmuxBinary: stub) },
            stopConnection: { connection in
                stopStarted.increment()
                stopGate.wait()  // held open until the test signals
                connection.stop()
            })
        // Never leave stop threads parked on failure (one per connection below).
        defer { for _ in 0..<3 { stopGate.signal() } }

        await supervisor.ensureConnection(serverName: "srv-a")
        await supervisor.ensureConnection(serverName: "srv-b")

        let stopAllDone = EventCounter()
        Task.detached {
            await supervisor.stopAll()
            stopAllDone.increment()
        }

        // stopAll must route through the injectable stop seam (pre-fix it
        // called connection.stop() directly ON the actor).
        #expect(await waitUntil(
            { stopStarted.count == 2 }, timeout: .seconds(15)), "stopAll never reached the stop seam")

        // While BOTH stops are still held open, an unrelated actor call must
        // complete promptly — pre-fix the actor is wedged inside the stops.
        // Unstructured on purpose (see slowStopDoesNotBlockActor).
        let unrelatedDone = EventCounter()
        Task.detached {
            _ = await supervisor.command(server: "srv-third")
            unrelatedDone.increment()
        }
        #expect(await waitUntil({ unrelatedDone.count == 1 }, timeout: .seconds(10)),
                "supervisor actor is blocked by a mid-stop stopAll")

        // Bookkeeping ran BEFORE the stops: both clients already evicted.
        #expect(await supervisor.command(server: "srv-a") == nil)
        #expect(await supervisor.command(server: "srv-b") == nil)

        // R6-M4 consistency: while stopAll's stops are in flight the servers
        // are marked stopping, so a racing ensureConnection must park rather
        // than start a successor beside a still-dying tmux client process.
        let ensured = EventCounter()
        Task.detached {
            await supervisor.ensureConnection(serverName: "srv-a")
            ensured.increment()
        }
        // Bounded negative check: ample time to (incorrectly) create one.
        try await Task.sleep(for: .milliseconds(500))
        #expect(ensured.count == 0, "ensureConnection must park while stopAll's stop is in flight")

        stopGate.signal()
        stopGate.signal()
        #expect(await waitUntil({ stopAllDone.count == 1 }, timeout: .seconds(15)),
                "stopAll must return once its stops complete")
        // The parked ensureConnection resumes and creates a fresh connection:
        // the supervisor stays usable after stopAll (the reconnect-after-
        // stopAll contract in TmuxControlCommandClientIntegrationTests).
        #expect(await waitUntil({ ensured.count == 1 }, timeout: .seconds(15)),
                "parked ensureConnection must resume after stopAll finishes")
        #expect(await supervisor.command(server: "srv-a") != nil)

        stopGate.signal()  // pre-release the successor's stop
        await supervisor.stopAll()
    }
}

/// Minimal thread-safe counter for cross-thread test signals.
private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
