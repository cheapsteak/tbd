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
                stopGate.wait()  // held open until the test signals
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

        // State left the maps BEFORE stop() ran, so a successor connection can
        // be created while the old one is still stopping — no fd reuse hazard:
        // the successor opens its own fresh pty, and the old connection's
        // primary fd is closed only inside its own (still-running) stop().
        #expect(await supervisor.command(server: "srv-slow") == nil,
                "faulted connection's client must be evicted before stop()")
        await supervisor.ensureConnection(serverName: "srv-slow")
        #expect(await supervisor.command(server: "srv-slow") != nil,
                "a successor connection must be creatable while the old stop is in flight")

        stopGate.signal()   // release the held stop; it stops the stub process
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
