import Clocks
import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The daemon-side half of the holder rendezvous, driven against real holder
/// processes spawned through the real `HolderSpawner`.
///
/// Four rules shape the suite, each one a bug it would otherwise ship:
///
///   1. **Every wait is a bounded poll.** A holder that wedges must fail a test
///      with a named diagnostic, not hang the suite with no output.
///   2. **Every bootstrap is rc-free.** `/bin/sh` with an explicit environment,
///      never a login shell — a developer's profile must not decide whether a
///      test passes.
///   3. **Every test kills its holder AND its job.** Holder death is
///      deliberately not child death, so a test that terminates a holder
///      orphans a `sleep` that no reconciler covers yet.
///   4. **No `setenv`.** The rendezvous paths come from an explicit environment
///      dictionary handed to `spawn`, so nothing here can reach the developer's
///      real `~/tbd` even for an instant.
@Suite(.serialized)
struct HolderClientTests {

    // MARK: - Spawning

    @Test func spawnsAHolderAndDescribesItsChild() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }

        #expect(fixture.handle.childPID > 0)
        #expect(fixture.handle.holderPID > 0)
        #expect(processIsAlive(fixture.handle.childPID))
        #expect(processIsAlive(fixture.handle.holderPID))

        // The spawner closes its handshake connection, so the holder's single
        // client slot is free for a fresh one — which is what every later
        // daemon-side consumer relies on.
        let client = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(5))
        let description = try await client.describe()
        await client.close()
        #expect(description.childPID == fixture.handle.childPID)
        #expect(description.status == .alive)
        #expect(description.ttyName.hasPrefix("/dev/"))
        // `--owner` is passed through as given: it names the installation, not
        // the process, so a restarted daemon still recognises its own holders.
        #expect(description.owner == fixture.owner)
    }

    @Test func handsOverAReadablePTY() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "printf HOLDER-OK; sleep 30")
        defer { fixture.tearDown() }

        let client = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(5))
        let (description, ptyFD) = try await client.handOverPTY()
        defer { Darwin.close(ptyFD) }
        await client.close()
        #expect(description.childPID == fixture.handle.childPID)
        #expect(ptyFD >= 0)

        var seen = Data()
        let sawMarker = waitUntilTrue("the job's output on the handed-over pty") {
            drainPTYInto(ptyFD, &seen)
            return String(decoding: seen, as: UTF8.self).contains("HOLDER-OK")
        }
        #expect(sawMarker, "read \(seen.count) bytes: \(String(decoding: seen, as: UTF8.self).debugDescription)")
    }

    // MARK: - The creation lock

    /// The regression test for the exact hazard the lock exists to prevent.
    ///
    /// A socket file cannot distinguish a live holder from the corpse of a
    /// SIGKILLed one, so "unlink the stale socket, then bind" is a race two
    /// spawners can both win. A spawner that cannot take the lock has already
    /// learned a live holder owns this UUID and must touch nothing.
    @Test func refusesToClearASocketWhoseLockIsHeld() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)
        try FileManager.default.createDirectory(
            atPath: TBDConstants.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let session = UUID()
        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        let lockPath = try HolderRendezvous.lockPath(sessionID: session, environment: environment)

        // Stand in for a live holder's bound socket. What matters to the
        // assertion is only that *something* occupies the path.
        try Data("not really a socket".utf8).write(to: URL(fileURLWithPath: socketPath))

        let lock = try HolderLock.acquire(path: lockPath)
        defer { lock.release() }

        let spawner = try SpawnedHolderFixture.makeSpawner()
        var thrown: Swift.Error?
        do {
            _ = try await spawner.spawn(
                sessionID: session,
                launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                owner: HolderOwnerToken(rawValue: "acme-installation"),
                environment: environment)
        } catch {
            thrown = error
        }

        guard case .lockHeldByLiveHolder(let reported, _)? = thrown as? HolderSpawner.Error else {
            Issue.record("expected .lockHeldByLiveHolder, got \(String(describing: thrown))")
            return
        }
        #expect(reported == session)
        // The other half of the assertion, and the one that actually guards the
        // hazard: the pre-existing socket is still there, byte for byte.
        #expect(FileManager.default.fileExists(atPath: socketPath))
        let survivor = try? Data(contentsOf: URL(fileURLWithPath: socketPath))
        #expect(survivor == Data("not really a socket".utf8))
    }

    // MARK: - Forget

    @Test func forgetStopsReporting() async throws {
        let fixture = try await SpawnedHolderFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        let childPID = fixture.handle.childPID

        let client = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(5))
        try await client.forget()
        await client.close()

        // A forgotten holder has nothing left to say, so it drops its pty and
        // exits, unlinking the socket on the way out.
        //
        // Exit is observed by reaping rather than by `kill(pid, 0)`: the holder
        // is this process's own child, so until somebody waits on it, it is a
        // zombie — and a zombie answers signal-zero exactly like a live process.
        #expect(fixture.reapHolder(), "the forgotten holder never exited")
        #expect(waitUntilTrue("the holder socket to be unlinked") {
            !FileManager.default.fileExists(atPath: fixture.handle.socketPath)
        })

        let reconnect = HolderClient(socketPath: fixture.handle.socketPath, receiveTimeout: .seconds(1))
        await #expect(throws: HolderClient.Error.self) {
            _ = try await reconnect.describe()
        }
        await reconnect.close()

        // And the job can be killed without anything resurrecting it — the
        // whole point of `forget` (iTerm2's preemptive wait, adopted for the
        // same reason).
        kill(childPID, SIGKILL)
        #expect(waitUntilTrue("the forgotten job to die") { !processIsAlive(childPID) })
    }

    // MARK: - The bind budget

    /// Proves the budget runs on the **injected** clock: the fake executable
    /// exits before it could bind anything, and the spawn only gives up once
    /// virtual time is advanced past `bindTimeout`. On wall time this test
    /// would take 200 ms of real waiting; on a `TestClock` it takes none, and a
    /// spawner that consulted `ContinuousClock` instead could not pass inside
    /// the helper's own real-time guard.
    @Test func spawnTimesOutIfTheHolderNeverBinds() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let environment = SpawnedHolderFixture.environment(home: home)

        let clock = TestClock<Duration>()
        let spawner = HolderSpawner(
            // Exits immediately and binds nothing. `/usr/bin/true` rather than a
            // written script so nothing about the fixture's own file creation
            // can be what the test measures.
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            bindTimeout: .milliseconds(200),
            bindPollInterval: .milliseconds(20),
            clock: clock)

        let outcome = ResultBox()
        let task = Task {
            do {
                _ = try await spawner.spawn(
                    sessionID: UUID(),
                    launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
                    owner: HolderOwnerToken(rawValue: "acme-installation"),
                    environment: environment)
                outcome.finish(nil)
            } catch {
                outcome.finish(error)
            }
        }

        let ranOut = await clock.advanceUntil("the bind budget to run out", by: .milliseconds(20)) {
            outcome.isFinished
        }
        #expect(ranOut)
        await task.value

        guard case .holderDidNotBind? = outcome.error as? HolderSpawner.Error else {
            Issue.record("expected .holderDidNotBind, got \(String(describing: outcome.error))")
            return
        }
    }

    // MARK: - The pending-message queue

    /// One `recvmsg` routinely carries a response and the holder's unsolicited
    /// exit push together — the holder answers a request and reports a status
    /// microseconds apart, and the kernel coalesces them.
    ///
    /// A client that returned the first frame and dropped the tail would then
    /// have to read again for a message it had already been handed, and since a
    /// holder closes right after reporting an exit that read is an EOF: the
    /// caller gets "the peer closed" for a report that did arrive. That was a
    /// real load-dependent flake in the holder's own harness.
    ///
    /// The peer here is a stub rather than a real holder precisely so the
    /// coalescing is *arranged* instead of raced: it writes both frames in a
    /// single `write` and then answers nothing else ever. With the queue the
    /// second read is served from memory; without it, it waits for a reply that
    /// will never come and dies on the receive timeout.
    @Test func queuesAResponseAndAnExitPushDeliveredInOneRead() async throws {
        let home = SpawnedHolderFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let socketPath = home + "/stub.sock"

        let alive = HolderChildDescription(
            childPID: 4242,
            ttyName: "/dev/ttys004",
            status: .alive,
            launch: SpawnedHolderFixture.launch(command: "sleep 30", home: home),
            owner: HolderOwnerToken(rawValue: "acme-installation"))
        var exited = alive
        exited.status = .exited(code: 7)

        var coalesced = Data()
        coalesced += try HolderFraming.frame(HolderResponse.described(alive))
        coalesced += try HolderFraming.frame(HolderResponse.described(exited))

        let peer = try CoalescingStubPeer(socketPath: socketPath, singleWrite: coalesced)
        defer { peer.tearDown() }

        let client = HolderClient(socketPath: socketPath, receiveTimeout: .seconds(2))
        let first = try await client.describe()
        #expect(first.status == .alive)

        // The discriminating half. The stub has stopped writing, so this can
        // only be answered from the queue.
        let second = try await client.describe()
        #expect(second.status == .exited(code: 7))
        #expect(second.childPID == 4242)
        await client.close()
    }
}

// MARK: - Support

/// Collects an async task's outcome for a test that has to drive a clock while
/// the task runs. A class with a lock rather than an actor so the clock-driving
/// loop can check it without awaiting a possibly-blocked actor.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var thrown: Swift.Error?

    func finish(_ error: Swift.Error?) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        thrown = error
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var error: Swift.Error? {
        lock.lock()
        defer { lock.unlock() }
        return thrown
    }
}

/// Poll until `condition` holds or the deadline passes.
@discardableResult
private func waitUntilTrue(
    _ description: String,
    timeout: TimeInterval = 10.0,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () throws -> Bool
) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        usleep(20_000)
    }
    Issue.record("timed out after \(timeout)s waiting for \(description)", sourceLocation: sourceLocation)
    return false
}

private func processIsAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Takes whatever is queued on a handed-over pty master, without blocking.
///
/// **A test that holds the master must drain it, or the job cannot finish
/// exiting.** The job is the pty's session leader, and XNU's `proc_exit` calls
/// `ttywait` on the controlling terminal before revoking it, so the process
/// stays in `P_WEXIT` until the tty's output queue is empty. Only a reader on
/// the master empties it, and the holder can never be that reader.
private func drainPTYInto(_ ptyFD: Int32, _ sink: inout Data) {
    _ = fcntl(ptyFD, F_SETFL, fcntl(ptyFD, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(ptyFD, &buffer, buffer.count)
        guard count > 0 else { return }
        sink.append(contentsOf: buffer[0..<count])
    }
}

/// A holder started the way the daemon starts one — through the real
/// `HolderSpawner`, with a real `posix_spawn` — plus everything needed to take
/// it back down.
private final class SpawnedHolderFixture {
    let home: String
    let sessionID: UUID
    let owner: HolderOwnerToken
    let handle: HolderHandle
    private var torndown = false

    private final class BundleMarker {}

    /// A short scratch root. Short on purpose: the rendezvous socket lives
    /// under it and `sun_path` is 104 bytes, so a deep `TMPDIR` would fail the
    /// bind rather than the assertion.
    static func scratchHome() -> String {
        "/tmp/tbdh6-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The environment the rendezvous paths are derived from *and* the holder
    /// process runs under. Explicit and rc-free: nothing here comes from the
    /// developer's shell, and `TBD_HOME` never leaves this dictionary.
    static func environment(home: String) -> [String: String] {
        ["TBD_HOME": home, "PATH": "/usr/bin:/bin"]
    }

    static func launch(command: String, home: String) -> HolderLaunchRequest {
        HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", command],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            columns: 80,
            rows: 24)
    }

    static func locateExecutable() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDHolder")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func makeSpawner(clock: any Clock<Duration> = ContinuousClock()) throws -> HolderSpawner {
        let executable = try #require(
            locateExecutable(), "TBDHolder must be built beside the test bundle")
        return HolderSpawner(executableURL: executable, clock: clock)
    }

    static func start(
        command: String,
        owner: String = "acme-installation",
        session: UUID = UUID()
    ) async throws -> SpawnedHolderFixture {
        let home = scratchHome()
        let token = HolderOwnerToken(rawValue: owner)
        let spawner = try makeSpawner()
        let handle = try await spawner.spawn(
            sessionID: session,
            launch: launch(command: command, home: home),
            owner: token,
            environment: environment(home: home))
        return SpawnedHolderFixture(
            home: home, sessionID: session, owner: token, handle: handle)
    }

    private init(home: String, sessionID: UUID, owner: HolderOwnerToken, handle: HolderHandle) {
        self.home = home
        self.sessionID = sessionID
        self.owner = owner
        self.handle = handle
    }

    private var reaped = false

    /// Polls for the holder to exit on its own and reaps it.
    ///
    /// `kill(pid, 0)` cannot answer this question: the holder is this process's
    /// child, so between its exit and somebody waiting on it, it is a zombie —
    /// and a zombie is signallable. Reaping is therefore the only observation
    /// that distinguishes "exited" from "still running".
    @discardableResult
    func reapHolder(timeout: TimeInterval = 10.0) -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitpid(handle.holderPID, &status, WNOHANG) == handle.holderPID {
                reaped = true
                return true
            }
            usleep(20_000)
        }
        return false
    }

    /// Kills the holder AND the job, in that order, then removes the scratch
    /// root. Holder death is not child death, so both need naming. The holder
    /// is this process's own child — the spawner `posix_spawn`s it directly —
    /// so it must also be reaped, or the corpse outlives the suite.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        if !reaped {
            kill(handle.holderPID, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(handle.holderPID, &ignored, 0)
            reaped = true
        }
        if processIsAlive(handle.childPID) { kill(handle.childPID, SIGKILL) }
        // The job is the holder's child, not ours, so nothing here can reap it;
        // the kernel reparents and reaps. Confirm it is gone so a leak fails the
        // test that caused it rather than the next run.
        waitUntilTrue("the holder's job to disappear", timeout: 5.0) {
            !processIsAlive(handle.childPID)
        }
        try? FileManager.default.removeItem(atPath: home)
    }
}

/// A stub peer that writes a prepared byte string in exactly one `write` on its
/// first read, and then answers nothing ever again.
///
/// Deliberately not a holder: the property under test is what the *client* does
/// when two frames land in one read, and racing a real holder into coalescing
/// them would make the test load-dependent — which is precisely the failure
/// mode being closed.
private final class CoalescingStubPeer: @unchecked Sendable {
    private let listenFD: Int32
    private let socketPath: String
    private let lock = NSLock()
    private var connectionFD: Int32 = -1
    private var stopped = false

    init(socketPath: String, singleWrite: Data) throws {
        self.socketPath = socketPath
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listenFD >= 0, "could not create the stub peer's socket")

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) { addressPtr in
            addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listenFD, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0, "could not bind the stub peer at \(socketPath) (errno \(errno))")
        try #require(listen(listenFD, 4) == 0, "could not listen on the stub peer's socket")

        let listener = listenFD
        let thread = Thread { [weak self] in
            let incoming = accept(listener, nil, nil)
            guard incoming >= 0, let self else {
                if incoming >= 0 { Darwin.close(incoming) }
                return
            }
            self.adopt(incoming)
            var scratch = [UInt8](repeating: 0, count: 256)
            // Wait for the client's first request, so the two frames are a
            // reply rather than an unsolicited greeting.
            _ = read(incoming, &scratch, scratch.count)
            _ = singleWrite.withUnsafeBytes { raw in
                Darwin.write(incoming, raw.baseAddress, raw.count)
            }
            // Park with the connection open. Closing here would let the client
            // reach EOF, which is the very thing the queue is meant to make
            // unnecessary — an EOF would mask a missing queue as a pass.
            while !self.isStopped { usleep(20_000) }
        }
        thread.name = "holder-stub-peer"
        thread.start()
    }

    private func adopt(_ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        connectionFD = fd
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func tearDown() {
        lock.lock()
        stopped = true
        let connection = connectionFD
        connectionFD = -1
        lock.unlock()
        if connection >= 0 { Darwin.close(connection) }
        Darwin.close(listenFD)
        unlink(socketPath)
    }
}
