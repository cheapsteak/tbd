import Darwin
import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib

/// R7-H1: a wedged pty write must not deadlock `stop()`. `sendCommand` holds
/// `ioLock` across a blocking full-write loop; if tmux stops draining the pty
/// the kernel input queue fills (TTYHOG) and the write parks forever holding
/// the lock. `stop()` must make forward progress WITHOUT first acquiring that
/// lock: terminating the child tears the pty down, the blocked write fails
/// with EIO, and only then is the lock needed for fd bookkeeping. Compounded
/// by R6-M4: teardown marks the server `stopping` BEFORE `stop()`, so a
/// deadlocked stop would park every future `ensureConnection` for that server
/// until daemon restart.
///
/// These tests wedge a write for real: a stub "tmux" holds the pty replica
/// open and never reads its stdin, and a 1 MB `sendCommand` from a background
/// thread parks in `write()`. Each stub records its own pid, and the
/// failure-path cleanup kills by that pid, so it can never reach another
/// run's stub.
@Suite("TmuxControlConnection wedged-write teardown (R7-H1)")
struct TmuxControlConnectionWedgedWriteTests {

    /// Executable stub "tmux" that ignores its args, records its pid, holds the
    /// pty replica open, and never reads stdin — so a big master-side write
    /// wedges.
    ///
    /// It sleeps `TestDeadlines.outlivingChildSeconds`, past every wait before
    /// and including the last one that checks the write was unwedged — three
    /// `saturatedPass` waits and a 300 ms settle — because a stub that ended
    /// on its own would tear the pty down and unwedge the write without
    /// `stop()` having killed it.
    private func makeStub() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-wedge-stub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("stub-tmux.sh").path
        let pidFile = Self.pidFile(forStub: path)
        try "#!/bin/sh\necho $$ > '\(pidFile)'\nexec sleep \(TestDeadlines.outlivingChildSeconds)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Where the stub at `stub` records its pid: `$$` is the shell's, and
    /// `exec` keeps it, so this is the pid of the `sleep` itself.
    private static func pidFile(forStub stub: String) -> String {
        ((stub as NSString).deletingLastPathComponent as NSString).appendingPathComponent("stub.pid")
    }

    /// Kill a leftover stub by the pid it recorded. A no-op on the green path
    /// (stop() already killed it); on the red/failure path this is what
    /// unwedges the parked write so leaked threads can exit. By pid, never by
    /// name pattern: another worktree running this suite has a stub with the
    /// same command line.
    private func killStub(_ stub: String) {
        guard let text = try? String(contentsOfFile: Self.pidFile(forStub: stub), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        kill(pid, SIGKILL)
    }

    /// Park a background thread inside `sendCommand` and confirm it is wedged
    /// (entered, not returned, and still stuck after a settle delay).
    private func wedgeWrite(
        on connection: TmuxControlConnection, returned: EventCounter
    ) async throws {
        let started = EventCounter()
        Thread.detachNewThread {
            started.increment()
            // ~1 MB: orders of magnitude beyond the pty input queue (TTYHOG),
            // so the full-write loop parks in `write()` holding `ioLock`.
            connection.sendCommand(String(repeating: "x", count: 1_000_000))
            returned.increment()
        }
        #expect(await waitUntil({ started.count == 1 }, timeout: TestDeadlines.saturatedPass))
        try await Task.sleep(for: .milliseconds(300))  // let it park in write()
        #expect(returned.count == 0, "precondition: the pty write should be wedged")
    }

    @Test("stop() returns bounded while a pty write is wedged, and releases the writer")
    func stopReturnsWhileWriteWedged() async throws {
        let stub = try makeStub()
        defer {
            killStub(stub)
            try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent)
        }

        let connection = TmuxControlConnection(serverName: "srv-wedge-a", tmuxBinary: stub)
        try connection.start()

        let sendReturned = EventCounter()
        try await wedgeWrite(on: connection, returned: sendReturned)

        // stop() must not deadlock behind the wedged writer's ioLock. Run it
        // on its own thread so a pre-fix deadlock fails the assertion instead
        // of hanging the test task forever.
        let stopReturned = EventCounter()
        Thread.detachNewThread {
            connection.stop()
            stopReturned.increment()
        }
        #expect(
            await waitUntil({ stopReturned.count == 1 }, timeout: TestDeadlines.saturatedPass),
            "stop() deadlocked behind a wedged pty write")

        // Killing the child tears the pty down, so the parked write must fail
        // (EIO — empirically NOT a process-killing SIGPIPE) and return.
        #expect(
            await waitUntil({ sendReturned.count == 1 }, timeout: TestDeadlines.saturatedPass),
            "the wedged sendCommand never unwedged after the child died")

        // Post-stop the fd is retired: further sends are refused, not crashed.
        connection.sendCommand("noop")
    }

    @Test("a wedged write cannot permanently starve ensureConnection for the server (R7-H1 + R6-M4)")
    func wedgedWriteDoesNotStarveSuccessor() async throws {
        let stub = try makeStub()
        defer {
            killStub(stub)
            try? FileManager.default.removeItem(atPath: (stub as NSString).deletingLastPathComponent)
        }

        let stopStarted = EventCounter()
        let stopFinished = EventCounter()
        let connectionBox = ConnectionBox()
        let supervisor = TmuxControlSupervisor(
            makeConnection: { server in
                let connection = TmuxControlConnection(serverName: server, tmuxBinary: stub)
                connectionBox.append(connection)
                return connection
            },
            stopConnection: { connection in
                stopStarted.increment()
                connection.stop()  // the REAL stop — this is what must not deadlock
                stopFinished.increment()
            })

        await supervisor.ensureConnection(serverName: "srv-wedge-b")
        let client = try #require(await supervisor.command(server: "srv-wedge-b"))
        let connection = try #require(connectionBox.first)

        let sendReturned = EventCounter()
        try await wedgeWrite(on: connection, returned: sendReturned)

        // Trigger the real fatal path: a client-originated reply block with an
        // empty queue is a correlator protocol violation → onFatalError →
        // teardown. Eviction marks the server `stopping` BEFORE stop() runs.
        await client.handle(.commandSucceeded(number: 1, fromClient: true, lines: []))
        #expect(
            await waitUntil({ stopStarted.count == 1 }, timeout: TestDeadlines.saturatedPass),
            "teardown never reached stop()")

        // Pre-fix, stop() deadlocks on the wedged writer's ioLock, the server
        // stays marked `stopping` forever, and this ensureConnection parks
        // permanently — control mode for the server is dead until daemon
        // restart. Post-fix, stop() kills the child, returns bounded, and
        // finishTeardown resumes the waiter into exactly one successor.
        let ensured = EventCounter()
        Task.detached {
            await supervisor.ensureConnection(serverName: "srv-wedge-b")
            ensured.increment()
        }
        #expect(
            await waitUntil({ ensured.count == 1 }, timeout: TestDeadlines.saturatedPass),
            "ensureConnection permanently suspended — the wedged stop never finished")
        #expect(stopFinished.count == 1)
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

/// Thread-safe box recording connections the supervisor seam created.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [TmuxControlConnection] = []
    func append(_ connection: TmuxControlConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
    }
    var first: TmuxControlConnection? {
        lock.lock(); defer { lock.unlock() }; return connections.first
    }
}
