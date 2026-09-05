import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

// A dying daemon must not unlink a live successor's socket.
//
// The socket path is a rendezvous every daemon generation binds in turn: a new
// daemon's `start()` removes whatever file is there and binds its own. If the
// outgoing daemon's `stop()` then unlinks on existence alone, it deletes the
// successor's socket. The successor never finds out — it keeps accepting on a
// listener no client can reach, and every client fails against a path that is
// simply gone. Only the file's identity, not its name, tells the two apart.
@Suite("SocketServer socket-file ownership")
struct SocketServerSocketOwnershipTests {

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

    /// `st_ino` of whatever is at `path`, or nil if nothing is. This is the
    /// identity the fix turns on — a path check alone cannot tell one server's
    /// socket from another's.
    private func inode(of path: String) -> ino_t? {
        socketFileInode(at: path)
    }

    /// Open an AF_UNIX/SOCK_STREAM client and connect() to `path`. Returns the
    /// connected fd, or -1. This is the client's-eye view: it is what actually
    /// breaks when the socket file is unlinked out from under a live listener.
    private func connectRawClient(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                UnsafeMutableRawPointer(pathPtr).copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Short /tmp path, well under the ~104-byte `sun_path` limit. NOT ~/tbd/sock.
    private func scratchSocketPath() -> String {
        "/tmp/tbd-sockown-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("a stopping server leaves a successor's socket at the same path alone")
    func successorSocketSurvivesPredecessorStop() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Daemon A binds the rendezvous path.
        let serverA = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await serverA.start()
        let inodeA = try #require(inode(of: socketPath))

        // Daemon B takes the path over: its start() unlinks A's file and binds
        // its own, so the path now names a different inode.
        let serverB = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await serverB.start()
        let inodeB = try #require(inode(of: socketPath))
        #expect(inodeB != inodeA, "B's bind must produce a new inode, or this test proves nothing")

        // A shuts down afterwards — the orphaned-daemon case.
        await serverA.stop()

        // B's socket must still be there, and must still be B's.
        #expect(inode(of: socketPath) == inodeB, "A's stop() deleted the live successor's socket")

        // And a client must still be able to reach B through the path.
        let clientFd = connectRawClient(to: socketPath)
        #expect(clientFd >= 0, "clients can no longer reach the live daemon at \(socketPath)")
        if clientFd >= 0 { close(clientFd) }

        await serverB.stop()
    }

    @Test("a stopping server still reclaims the socket it bound itself")
    func serverReclaimsItsOwnSocket() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        let server = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await server.start()
        #expect(inode(of: socketPath) != nil)

        await server.stop()

        // Nobody else took the path over, so the file is this server's to clean
        // up. The ownership check must not turn into "never unlink".
        #expect(inode(of: socketPath) == nil, "a server must still reclaim its own socket file")
    }

    @Test("a server that never bound unlinks nothing")
    func neverStartedServerUnlinksNothing() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Somebody else's socket sits at the path.
        let incumbent = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await incumbent.start()
        let incumbentInode = try #require(inode(of: socketPath))

        // A second server is constructed but never starts — a daemon that lost
        // the race to bind and is now being torn down.
        let neverStarted = SocketServer(router: try makeRouter(), socketPath: socketPath)
        await neverStarted.stop()

        #expect(
            inode(of: socketPath) == incumbentInode,
            "stop() on a server that never bound deleted a live socket"
        )

        await incumbent.stop()
    }

    @Test("only one of many overlapping shutdowns claims the socket file")
    func onlyOneOverlappingShutdownClaimsTheFile() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Nothing serializes `stop()`: SIGTERM and SIGINT each fire their own
        // undeduplicated `Task { await daemon.stop() }` in main.swift, so a
        // supervisor escalating signals can run two shutdowns at once. Every
        // claimant goes on to unlink against the identity it came away with,
        // so a second claimant is a second unlink — aimed at a path a
        // successor may have taken over by then, which is the one thing the
        // identity exists to prevent. At most one claim, always.
        //
        // The read-and-clear window is a few instructions wide, so no amount
        // of starting threads and hoping will land inside it. `claimWindow`
        // holds it open instead: the first claimant waits until every other
        // thread has reached the call site, then lingers long enough for an
        // unsynchronized read to land in the window. Taken under a lock, the
        // others wait outside it and come away with nothing; taken with a
        // plain read-then-nil, all eight read the same identity.
        //
        // Every wait below is bounded and reached from a `gateHoldingTask`,
        // never from the cooperative pool: a blocked pool thread is one the
        // work that would release it can no longer run on, and the pool is
        // three threads wide on CI's runner. A task rather than a bare
        // `Thread` because the two things Swift Testing needs to attribute an
        // expired gate — `Test.current` and `Configuration.current` — are
        // task-locals, and a bare `Thread` has neither.
        let claimants = 8
        let atCallSite = DispatchSemaphore(value: 0)
        let windowIsHeld = FirstArrivalFlag()
        let claimWindow: @Sendable (SocketFileIdentity?) -> Void = { _ in
            guard windowIsHeld.takeFirst() else { return }
            for index in 0..<(claimants - 1) {
                atCallSite.waitForGate("claimant \(index + 2) of \(claimants) reaching the claim call site")
            }
            usleep(50_000)
        }

        let server = SocketServer(
            router: try makeRouter(),
            socketPath: socketPath,
            beforeAdoptingBoundSocket: nil,
            duringIdentityClaim: claimWindow
        )
        try await server.start()

        let claims = ClaimCounter()
        let finished = ClaimCounter()
        for _ in 0..<claimants {
            _ = gateHoldingTask {
                atCallSite.signal()
                if server.takeBoundSocketIdentity() != nil { claims.increment() }
                finished.increment()
            }
        }
        try await waitFor(
            "all \(claimants) claimant threads to finish",
            observed: { "\(finished.count) of \(claimants) finished" }
        ) { finished.count == claimants }
        #expect(
            claims.count == 1,
            "\(claims.count) of \(claimants) overlapping shutdowns came away owning the socket file; only one may"
        )

        await server.stop()
    }

    @Test("two overlapping shutdowns both finish, and the socket file is claimed once")
    func overlappingStopsBothFinishAndClaimTheFileOnce() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // The real path this branch exists to survive. SIGTERM and SIGINT each
        // fire an independent, undeduplicated `Task { await daemon.stop() }` in
        // main.swift, both reach `SocketServer.stop()` through `Daemon.stop()`,
        // and a supervisor escalating signals sends both. Running the shutdown
        // body twice hangs rather than merely repeating: `channel.close()` off
        // the event loop is `eventLoop.execute { ... }` fulfilling a promise,
        // and a loop whose group has shut down discards submitted work, so the
        // promise is never fulfilled. Both `stop()` calls must return, and the
        // socket file must be claimed once — a second claimant would go on to
        // unlink against a path a successor may hold by then.
        // The overlap is staged rather than hoped for, and staged at the point
        // that is actually dangerous: the second caller enters `stop()` while
        // the first is at its reclaim step — past `shutdownGracefully()`, so
        // the event loop is already gone. Two `stop()` calls that merely start
        // together are not this case, because both get their `channel.close()`
        // in while the loop is still alive; that ordering survives even
        // without the fix, so a test built on it proves nothing.
        //
        // Nothing this test starts parks a cooperative-pool thread: both
        // `stop()` calls and the thread that waits on the staging gate go
        // through `gateHoldingTask`, and every wait is bounded through
        // `waitForGate`. See Tests/CLAUDE.md, "Thread-blocking gates run off
        // the cooperative pool".
        //
        // **`gateHoldingTask` cannot reach the shutdown body, though.**
        // `SocketServer.stop()` hands that body to `ShutdownLatch`, which runs
        // it in an unstructured `Task` so a cancelled signal handler cannot
        // abandon a shutdown other callers await — and SE-0417 carries a task
        // executor preference into child tasks and default actors but *not*
        // into `Task {}`. So the work that signals the gate below is scheduled
        // on the cooperative pool however this test starts `stop()`,
        // competing with a parallel pass that admits all ~5,000 tests at once
        // against a 3-thread runner.
        //
        // That is a scheduling cost, not a wedge, and the gate's bound has to
        // absorb it.
        let claims = ClaimCounter()
        let firstShutdownIsAtTheReclaimStep = DispatchSemaphore(value: 0)
        let secondCallerHasArrived = DispatchSemaphore(value: 0)
        let holdTheFirstShutdown = FirstArrivalFlag()
        // The saturated-pass budget the rest of the repo derives its waits
        // from, and the observation below gets a strictly larger one. That
        // ordering is what makes a genuinely lost handshake report itself as a
        // lost handshake and degrade to the weaker "both stop() calls
        // returned" check, rather than surface as a wedge. A snappier bound
        // here reports starvation the outer bound was sized to tolerate:
        // measured on CI at 30 s, where the handshake was merely late and
        // every other assertion in this test still passed.
        let stagingDeadline: Duration = TestDeadlines.saturatedPass
        let bothStopsReturnedDeadline: Duration = TestGate.deadline
        let claimWindow: @Sendable (SocketFileIdentity?) -> Void = { identity in
            if identity != nil { claims.increment() }
            guard holdTheFirstShutdown.takeFirst() else { return }
            firstShutdownIsAtTheReclaimStep.signal()
            secondCallerHasArrived.waitForGate(
                "the second stop() caller to reach stop()", timeout: stagingDeadline)
            // Covers the hop between the second caller reaching `stop()` and
            // `stop()` reaching the latch, so the first shutdown is still
            // in flight when it gets there.
            usleep(50_000)
        }

        let server = SocketServer(
            router: try makeRouter(),
            socketPath: socketPath,
            beforeAdoptingBoundSocket: nil,
            duringIdentityClaim: claimWindow
        )
        try await server.start()
        #expect(inode(of: socketPath) != nil)

        // Unstructured and waited on with a deadline rather than gathered in
        // a task group: the failure under test is a shutdown that never
        // returns, and a task group would wedge the whole run alongside it
        // instead of reporting it.
        let finished = ClaimCounter()
        _ = gateHoldingTask {
            await server.stop()
            finished.increment()
        }
        // Off the cooperative pool so the bounded wait cannot occupy a thread
        // the first shutdown may need, and a task rather than a bare `Thread`
        // so an expired gate is attributed to this test: Swift Testing reads
        // `Test.current` and `Configuration.current` from task-locals, and
        // with neither it names the failure «unknown» and posts it to every
        // registered event handler rather than lose it — one expiry, several
        // identical lines.
        _ = gateHoldingTask {
            firstShutdownIsAtTheReclaimStep.waitForGate(
                "the first shutdown to reach its reclaim step", timeout: stagingDeadline)
            secondCallerHasArrived.signal()
            _ = gateHoldingTask {
                await server.stop()
                finished.increment()
            }
        }

        try await waitFor(
            "both overlapping stop() calls to return",
            deadline: bothStopsReturnedDeadline,
            observed: { "\(finished.count) of 2 returned" }
        ) { finished.count == 2 }
        #expect(
            claims.count == 1,
            "\(claims.count) of the overlapping shutdowns came away owning the socket file; exactly one may"
        )
        #expect(inode(of: socketPath) == nil, "the overlapping shutdowns left the socket file behind")
    }

    @Test("a second shutdown after a successor took over leaves the successor alone")
    func repeatStopLeavesTheSuccessorAlone() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // The sequential half of the same guarantee, and the case a signal
        // escalation actually produces most often: SIGTERM shuts the server
        // down, a successor daemon binds the rendezvous path, and SIGINT then
        // runs a second `stop()`. It must return, and it must claim nothing.
        let server = SocketServer(router: try makeRouter(), socketPath: socketPath)
        try await server.start()

        await server.stop()
        #expect(inode(of: socketPath) == nil, "the shutdown must still reclaim its own file")

        let successor = SuccessorSocket()
        defer { successor.release() }
        successor.takeOver(path: socketPath)
        let successorInode = try #require(successor.inode)

        let secondStopReturned = ClaimCounter()
        Task.detached {
            await server.stop()
            secondStopReturned.increment()
        }
        try await waitFor(
            "the second stop() to return",
            observed: { "\(secondStopReturned.count) of 1 returned" }
        ) { secondStopReturned.count == 1 }
        #expect(
            inode(of: socketPath) == successorInode,
            "a repeat shutdown deleted the successor's socket"
        )
    }

    /// The rendezvous path is cleared by whoever is about to bind it, and by
    /// nobody else. `SocketServer` is that code: `start()` clears the path
    /// immediately before `bind(2)`, and `stop()` reclaims the file only while
    /// the path still resolves to the inode it bound.
    ///
    /// Two startup paths used to remove it on the strength of a stale pid file
    /// — `PIDFile.cleanupIfStale()` and `AppState.startDaemonAndConnect()` —
    /// and a pid file reads as stale for as long as a successor has bound the
    /// socket without having rewritten it yet. Removing it there deletes a
    /// live daemon's socket and puts nothing in its place: the path stays
    /// empty for the whole of the next daemon's startup, and for good if that
    /// startup throws first.
    ///
    /// Pinned against the source text because those removals resolve
    /// `TBDConstants.socketPath` from the process environment, and the only
    /// runtime seam for that is a process-global this target must not mutate:
    /// `ConstantsTests` pins that no suite in this process sets
    /// `TBD_SOCKET_PATH`, and `scripts/test.sh` sets it for the whole run. A
    /// source pin is a weak instrument in general; here it is the available
    /// one.
    @Test("nothing outside SocketServer removes the rendezvous socket file")
    func onlyTheBinderClearsTheRendezvousPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TBDDaemonTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let fm = FileManager.default
        var offenders: [String] = []
        var scanned = 0

        for module in ["Sources/TBDDaemon", "Sources/TBDApp"] {
            let dir = root.appendingPathComponent(module)
            let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in files where file.lastPathComponent != "SocketServer.swift" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scanned += 1
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), code.contains("TBDConstants.socketPath") else { continue }
                    guard code.contains("removeItem") || code.contains("unlink(") else { continue }
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }

        #expect(scanned > 100, "the source scan found almost nothing to read — it is passing vacuously")
        #expect(
            offenders.isEmpty,
            "these remove the rendezvous socket without binding it: \(offenders.joined(separator: "; "))"
        )
    }

    @Test("a start that fails after binding leaves a successor's socket alone")
    func failedStartLeavesSuccessorSocketAlone() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // The other end of the same race, reached from startup rather than
        // shutdown. `start()` binds the rendezvous file and then awaits NIO
        // adopting the descriptor; that await is a suspension point, so a
        // successor daemon can bind the path inside it. If the adoption then
        // fails, the cleanup must not delete the file the successor now owns.
        let successor = SuccessorSocket()
        defer { successor.release() }

        let predecessor = SocketServer(
            router: try makeRouter(),
            socketPath: socketPath,
            beforeAdoptingBoundSocket: { boundFD in
                // This descriptor never reaches NIO, so close it here rather
                // than leak it for the life of the test process.
                close(boundFD)
                successor.takeOver(path: socketPath)
                throw AdoptionRefused()
            }
        )

        await #expect(throws: AdoptionRefused.self) {
            try await predecessor.start()
        }

        let predecessorInode = try #require(successor.displacedInode)
        let successorInode = try #require(successor.inode)
        #expect(
            successorInode != predecessorInode,
            "the successor's bind must produce a new inode, or this test proves nothing"
        )
        #expect(
            socketFileInode(at: socketPath) == successorInode,
            "the failed start deleted the live successor's socket"
        )

        // And the successor must still be reachable through the path.
        let clientFd = connectRawClient(to: socketPath)
        #expect(clientFd >= 0, "clients can no longer reach the live daemon at \(socketPath)")
        if clientFd >= 0 { close(clientFd) }

        // Tearing the failed server down afterwards must not finish the job
        // its failed start did not do — it bound nothing it still owns.
        await predecessor.stop()
        #expect(
            socketFileInode(at: socketPath) == successorInode,
            "stop() after a failed start deleted the live successor's socket"
        )
    }

    @Test("a start that fails after binding still reclaims the file it bound")
    func failedStartReclaimsItsOwnSocket() async throws {
        let socketPath = scratchSocketPath()
        defer { unlink(socketPath) }

        // Nobody takes the path over inside the window, so the file is this
        // server's to clean up. The ownership check on the failure path must
        // not degenerate into "never unlink" and strand a socket file.
        let server = SocketServer(
            router: try makeRouter(),
            socketPath: socketPath,
            beforeAdoptingBoundSocket: { boundFD in
                close(boundFD)
                throw AdoptionRefused()
            }
        )

        await #expect(throws: AdoptionRefused.self) {
            try await server.start()
        }

        #expect(
            socketFileInode(at: socketPath) == nil,
            "a failed start left its own socket file behind"
        )

        // Releases the event loop group the failed start left running.
        await server.stop()
    }
}

/// `st_ino` of whatever is at `path`, or nil if nothing is. `lstat` rather
/// than `stat`, matching the production check.
private func socketFileInode(at path: String) -> ino_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_ino
}

/// What NIO refusing the bound descriptor looks like to `start()`. The real
/// refusals are kernel-level and cannot be provoked in-process, so the test
/// injects the failure at the same point in the same window.
private struct AdoptionRefused: Error {}

/// A stand-in for a successor daemon taking the rendezvous path over: unlink
/// whatever is there, then `bind(2)` + `listen(2)` its own socket under the
/// same name — exactly what another daemon's `start()` leaves behind.
private final class SuccessorSocket: @unchecked Sendable {
    /// The inode this displaced, i.e. the predecessor's own socket file.
    private(set) var displacedInode: ino_t?
    /// The inode of the socket now at the path.
    private(set) var inode: ino_t?
    private var fd: Int32 = -1

    func takeOver(path: String) {
        displacedInode = socketFileInode(at: path)
        unlink(path)

        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(newFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(newFD, 8) == 0 else {
            close(newFD)
            return
        }
        fd = newFD
        inode = socketFileInode(at: path)
    }

    func release() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

/// Lets exactly one caller through — the first claimant, which is the one that
/// holds the read-and-clear window open for everybody else.
private final class FirstArrivalFlag: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()

    func takeFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Counts how many concurrent callers came away holding the socket file's
/// identity. The guarantee under test is that the answer is one.
private final class ClaimCounter: @unchecked Sendable {
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
