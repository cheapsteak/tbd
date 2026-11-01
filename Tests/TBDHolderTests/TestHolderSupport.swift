import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDHolder
import TBDKernel

// Scaffolding for the holder's live-process tests.
//
// Three rules shape all of it, and each one is a bug this suite would
// otherwise have shipped:
//
//   1. **Every wait is a bounded poll.** A holder that wedges must fail a test,
//      not hang the whole suite with no output and no named failure.
//   2. **Every bootstrap is rc-free.** `/bin/sh` with an explicit environment,
//      never a login shell — a developer's profile must not be able to change
//      whether a test passes.
//   3. **Every test kills its holder AND its job.** Holder death is
//      deliberately not child death, so a test that terminates a holder
//      orphans a `sleep` that no reconciler covers yet. Bounded at the sleep's
//      own duration, but it compounds across runs.

/// `CustomStringConvertible` as well as `LocalizedError`, for the same reason
/// `HolderWaitTimedOut` is: Swift Testing renders a caught error through its
/// `description`, so that text is what lands on the primary failure line.
/// Without it a CI summary shows only the bare case, `.connectFailed(path:
/// …, errno: 61)`, and drops the holder's log.
enum TestHolderError: LocalizedError, CustomStringConvertible {
    case executableNotFound
    case spawnFailed(Int32)
    case holderNeverReportedItsPID(diagnostics: String)
    case connectFailed(path: String, errno: Int32)
    /// `HolderFixture.connect` hit an error it does not retry; `underlying`
    /// is that error, with the holder's log beside it.
    case connectFailedWithHolderLog(underlying: any Error, diagnostics: String)
    /// Each of one `connect` call's attempts was refused (ECONNREFUSED), and
    /// the holder has since exited, so it can never start accepting.
    case holderExitedWhileRefusing(path: String, refusedAttempts: Int, diagnostics: String)
    /// Each of one `connect` call's attempts was refused while the holder
    /// stayed alive, until the shared deadline ran out.
    case connectRefusedUntilDeadline(path: String, refusedAttempts: Int, elapsed: Duration, diagnostics: String)
    case noResponse

    var description: String {
        switch self {
        case .executableNotFound:
            return "TBDHolder was not built into the products directory"
        case .spawnFailed(let code):
            return "posix_spawn of the holder bootstrap failed with code \(code)"
        case .holderNeverReportedItsPID(let diagnostics):
            return "the bootstrap shell never wrote a holder pid.\n\(diagnostics)"
        case .connectFailed(let path, let code):
            return "could not connect to \(path): \(String(cString: strerror(code))) (errno \(code))"
        case .connectFailedWithHolderLog(let underlying, let diagnostics):
            return "\(underlying)\n\(diagnostics)"
        case .holderExitedWhileRefusing(let path, let attempts, let diagnostics):
            return "all \(attempts) of this call's connect attempts to \(path) were refused "
                + "(errno \(ECONNREFUSED)), and the holder has since exited\n\(diagnostics)"
        case .connectRefusedUntilDeadline(let path, let attempts, let elapsed, let diagnostics):
            return "the deadline ran out with all \(attempts) of this call's connect attempts to \(path) "
                + "refused (errno \(ECONNREFUSED)) over \(elapsed); the holder was still alive at the last one"
                + "\n\(diagnostics)"
        case .noResponse:
            return "the holder closed the connection without answering"
        }
    }

    var errorDescription: String? { description }
}

/// Poll until `condition` holds or the deadline passes.
///
/// Suspends between probes rather than sleeping the thread: these suites run
/// in the fast parallel pass, where a thread parked in `usleep` is one of the
/// three the whole process shares. The verdict comes from `pollUntilTrue`'s
/// fresh read after the deadline, so a resumption that lands late under load
/// still reports a condition that has since come true.
///
/// The deadline defaults to `TestDeadlines.saturatedPassSeconds`, per
/// `Tests/CLAUDE.md`: what these waits watch is a real holder process, which
/// that pass's load slows as much as anything else in it, and a green run
/// never pays for the budget. `description` is read only on a timeout, so a
/// diagnostic that interpolates the holder's log reports the log as it stood
/// when the wait gave up.
@discardableResult
func waitUntil(
    _ description: @autoclosure () -> String,
    timeout: TimeInterval = TestDeadlines.saturatedPassSeconds,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async -> Bool {
    let started = ContinuousClock.now
    let outcome = await pollUntilTrue(
        timeout: .seconds(timeout), pollInterval: .milliseconds(20)
    ) {
        condition()
    }
    switch outcome {
    case .satisfied:
        return true
    case .cancelled:
        // The harness ended the test; attribution belongs to it, not here.
        return false
    case .timedOut:
        Issue.record(
            HolderWaitTimedOut(
                what: description(), budget: timeout, elapsed: ContinuousClock.now - started),
            sourceLocation: sourceLocation)
        return false
    }
}

/// The blocking form of `waitUntil`, for the one caller that cannot suspend:
/// `HolderFixture.tearDown`, which runs from a `defer`. It follows a SIGKILL,
/// so it normally ends on its first probe or two. Its bound stays short on
/// purpose, unlike `waitUntil`'s: this one parks a cooperative-pool thread for
/// as long as it runs, and a leaked holder is what it reports, not a slow one.
@discardableResult
private func blockingWaitUntil(
    _ description: String,
    timeout: TimeInterval,
    _ condition: () -> Bool
) -> Bool {
    let started = ContinuousClock.now
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    if condition() { return true }
    Issue.record(
        HolderWaitTimedOut(what: description, budget: timeout, elapsed: ContinuousClock.now - started))
    return false
}

/// A bounded wait in this target expired. An `Error` rather than a string, so
/// its text lands on the primary failure line a CI summary keeps
/// (`Tests/CLAUDE.md`, "Assertion hygiene" rule 4).
struct HolderWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let budget: TimeInterval
    let elapsed: Duration

    var description: String {
        "gave up after \(elapsed) (budget \(budget)s) waiting for \(what)"
    }
}

func processIsAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Takes whatever is queued on a handed-over pty master, without blocking.
///
/// **A test that holds the master must drain it, or the job cannot finish
/// exiting.** The job is the pty's session leader, and XNU's `proc_exit` calls
/// `ttywait` on the controlling terminal before revoking it: the process stays
/// in `P_WEXIT` — `ps` shows state `?Es` and parenthesises the command — until
/// the tty's output queue is empty. Only a reader on the master empties it.
///
/// The holder cannot be that reader; never reading the master is its central
/// invariant, because a byte it consumed is a byte no reader can ever see
/// again. So an undrained master wedges the job's exit, `waitpid(…, WNOHANG)`
/// correctly keeps reporting 0, and the holder never observes a status to
/// report. Four bytes of canonical-mode echo are enough — that is exactly what
/// wedged `reportsTheJobsExitCodeToAConnectedClient`.
///
/// Made non-blocking on the caller's behalf, since a master with nothing queued
/// would otherwise block the very poll that is trying to make progress.
func drainPTY(_ ptyFD: Int32, into sink: inout Data) {
    _ = fcntl(ptyFD, F_SETFL, fcntl(ptyFD, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(ptyFD, &buffer, buffer.count)
        guard count > 0 else { return }
        sink.append(contentsOf: buffer[0..<count])
    }
}

/// A holder started the way the daemon will start one, plus everything needed
/// to take it back down.
///
/// The holder is deliberately **not** a child of the test process. A short
/// bootstrap `/bin/sh` is spawned, backgrounds the holder, and exits; the test
/// reaps the shell. Every fixture therefore already satisfies the design's
/// central claim — the process that spawned the holder is gone — and
/// `childSurvivesTheSpawningProcessExiting` asserts it rather than arranging
/// it.
final class HolderFixture {
    let home: String
    let sessionID: UUID
    let socketPath: String
    let lockPath: String
    let stderrPath: String
    let holderPID: Int32
    /// The bootstrap shell's exit status, or nil if it never exited.
    let spawnerExitStatus: Int32?

    private var trackedChildPID: Int32 = 0
    private var torndown = false

    private final class BundleMarker {}

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

    /// A short scratch root under the run root `scripts/test.sh` reclaims.
    /// Short on purpose: the rendezvous socket lives under it and `sun_path` is
    /// 104 bytes, so a deeper root would push the path over the limit and fail
    /// the bind rather than the assertion. Fenced on purpose too — `tearDown`
    /// cannot run when the test process is killed, and the wrapper's EXIT trap
    /// is the only thing that reclaims the root in that case.
    ///
    /// Exposed so a test can name paths inside it — a marker file the job
    /// writes — while building the launch request, before the fixture exists.
    static func scratchHome() -> String {
        fencedScratchRoot(prefix: "tbdh")
    }

    /// The descriptor number `strayDescriptorProbe` plants a leaked fd on.
    /// Above the lock's 9 so the two file actions cannot collide.
    static let strayDescriptorNumber: Int32 = 11

    // swiftlint:disable:next function_body_length
    static func start(
        launch: HolderLaunchRequest,
        owner: String = "test-installation",
        session: UUID = UUID(),
        /// When true, an ordinary file descriptor is planted at
        /// `strayDescriptorNumber` in the bootstrap shell and inherited by the
        /// holder, standing in for whatever a real spawner happens to have open
        /// without `FD_CLOEXEC`. The job must not receive it.
        strayDescriptorProbe: Bool = false,
        /// Must match the root any marker paths inside `launch` were built
        /// from; defaults to a fresh one.
        home: String = HolderFixture.scratchHome()
    ) async throws -> HolderFixture {
        let executable = try #require(locateExecutable(), "TBDHolder must be built beside the test bundle")
        let environment = ["TBD_HOME": home]
        try FileManager.default.createDirectory(
            atPath: KernelPaths.holdersDir(environment: environment).path,
            withIntermediateDirectories: true)

        let socketPath = try HolderRendezvous.socketPath(sessionID: session, environment: environment)
        let lockPath = try HolderRendezvous.lockPath(sessionID: session, environment: environment)
        let stderrPath = home + "/holder.log"
        let pidPath = home + "/holder.pid"

        // The spawner takes the lock and hands the DESCRIPTOR down; the holder
        // never acquires it itself. This is the production sequence, not a
        // stand-in for it.
        let lock = try HolderLock.acquire(path: lockPath)
        var lockReleased = false
        defer { if !lockReleased { lock.release() } }

        // The launch request travels on a DESCRIPTOR, never on argv — argv is
        // readable with `ps` by anything running as the same user, and the
        // request carries the session's whole environment. Production places
        // that descriptor with a `posix_spawn` file action; the bootstrap shell
        // gets there with a redirect from a file in its own scratch home, which
        // `teardown` removes with the rest of it.
        let launchPath = home + "/launch.json"
        try JSONEncoder().encode(launch).write(to: URL(fileURLWithPath: launchPath))
        let command = [
            shellQuoted(executable.path),
            "--session", shellQuoted(session.uuidString),
            "--socket", shellQuoted(socketPath),
            "--lock-fd", "9",
            "--launch-fd", "3",
            "--owner", shellQuoted(owner),
            "3<", shellQuoted(launchPath),
            "&",
            "echo $! >", shellQuoted(pidPath),
        ].joined(separator: " ")

        // O_CLOEXEC on both: they are dup2'd onto the child's stdio, and the
        // originals must then vanish at exec rather than leaking down into the
        // job. Setting FD_CLOEXEC is the safe direction — CLEARING it on a
        // parent descriptor would expose it to every other concurrent
        // posix_spawn in this process.
        let logFD = open(stderrPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        let nullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer {
            if logFD >= 0 { close(logFD) }
            if nullFD >= 0 { close(nullFD) }
        }

        // `dup2(fd, fd)` succeeds WITHOUT clearing FD_CLOEXEC, so a lock that
        // already sits on the target number would be closed at exec and the
        // holder would refuse to start. `F_DUPFD_CLOEXEC` hands back the lowest
        // free number at or above 10, past the target, and keeps the duplicate
        // close-on-exec, as `HolderSpawner` and `HolderLockTests` do. A plain
        // `dup` would clear FD_CLOEXEC, and the copy stays open here until this
        // function returns: every test target links into one process, so a
        // sibling suite's spawn in that window would inherit the lock and hold
        // it after the holder died, and `theJobDoesNotInheritTheCreationLock`
        // would fail with `.alreadyHeld` about somebody else's child. With a
        // plain `dup` here, that failure measured about 6 runs in 1,000; it can
        // arise only when the lock lands on 9, the one case that relocates.
        var lockSource = lock.fileDescriptor
        var relocated: Int32 = -1
        if lockSource == 9 {
            relocated = fcntl(lockSource, F_DUPFD_CLOEXEC, 10)
            try #require(relocated >= 0, "could not move the lock off the target descriptor")
            lockSource = relocated
        }
        defer { if relocated >= 0 { close(relocated) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // File actions run IN ORDER. The stdio dup2s come first, then the
        // lock's, then the probe's below, so a source that sits on a LATER
        // action's target — the log or /dev/null on 9 or 11, the lock on 11 —
        // has already been copied to its final home by the time that target is
        // overwritten. There are deliberately NO trailing closes: a
        // close scheduled after the lock's dup2 would destroy the descriptor it
        // just placed, and O_CLOEXEC already retires the originals at exec.
        posix_spawn_file_actions_adddup2(&actions, nullFD, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_adddup2(&actions, lockSource, 9)

        var strayFD: Int32 = -1
        var strayRelocated: Int32 = -1
        defer {
            if strayRelocated >= 0 { close(strayRelocated) }
            if strayFD >= 0 { close(strayFD) }
        }
        if strayDescriptorProbe {
            strayFD = open(home + "/stray.probe", O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            try #require(strayFD >= 0, "could not open the stray-descriptor probe")
            // Moved above every target whenever it sits on one, not only on
            // its own. On 11 it meets the lock's `dup2(fd, fd)` hazard. On 0,
            // 1, 2 or 9 an earlier action would overwrite it before its own
            // dup2 runs: on 9, which is free whenever the lock is not there,
            // the lock's dup2 would land first and the probe's dup2 would then
            // copy the LOCK onto 11, so `theJobDoesNotInheritStrayDescriptors`
            // would pass however the holder treated 11. At 12 or above the
            // source is no action's target, so nothing can overwrite it before
            // it is copied, whatever order the actions run in.
            let fileActionTargets: Set<Int32> = [0, 1, 2, 9, strayDescriptorNumber]
            var straySource = strayFD
            if fileActionTargets.contains(straySource) {
                strayRelocated = fcntl(straySource, F_DUPFD_CLOEXEC, strayDescriptorNumber + 1)
                try #require(strayRelocated >= 0, "could not move the probe off the target descriptor")
                straySource = strayRelocated
            }
            posix_spawn_file_actions_adddup2(&actions, straySource, strayDescriptorNumber)
        }

        var shellPID: pid_t = 0
        let argvStrings = ["sh", "-c", command]
        var argv = argvStrings.map { strdup($0) }
        argv.append(nil)
        // An explicit, rc-free environment: `sh -c` reads no profile, and
        // nothing here comes from the developer's shell.
        let envpStrings = ["PATH=/usr/bin:/bin", "TBD_HOME=\(home)"]
        var envp = envpStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }

        // CLOEXEC_DEFAULT, as `HolderSpawner` asks for: the shell, and the
        // holder it backgrounds, get the descriptors named by a file action
        // above (0, 1, 2, the lock on 9, and the probe on 11 when asked for)
        // and nothing else. The launch request on 3 is opened by the shell's
        // own redirect after exec. Without the flag, every test holder would
        // inherit whatever any concurrent suite in this process had open
        // without FD_CLOEXEC, and keep it for the holder's whole life.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let spawned = posix_spawn(&shellPID, "/bin/sh", &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw TestHolderError.spawnFailed(spawned) }

        // The holder now owns the lock through its own copy of the open file
        // description. Dropping ours makes it the sole holder, which is what
        // `theJobDoesNotInheritTheCreationLock` goes on to assert.
        lock.release()
        lockReleased = true

        var raw: Int32 = 0
        var reaped = false
        await waitUntil("the bootstrap shell to exit") {
            if waitpid(shellPID, &raw, WNOHANG) == shellPID { reaped = true }
            return reaped
        }
        if !reaped {
            kill(shellPID, SIGKILL)
            _ = waitpid(shellPID, &raw, 0)
        }
        let exitStatus: Int32? = reaped ? ((raw >> 8) & 0xff) : nil

        var holderPID: Int32 = 0
        let reported = await waitUntil("the bootstrap shell to report a holder pid") {
            guard let text = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return false }
            holderPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return holderPID > 0
        }
        guard reported else {
            let log = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "<no holder output>"
            throw TestHolderError.holderNeverReportedItsPID(diagnostics: log)
        }

        return HolderFixture(
            home: home,
            sessionID: session,
            socketPath: socketPath,
            lockPath: lockPath,
            stderrPath: stderrPath,
            holderPID: holderPID,
            spawnerExitStatus: exitStatus)
    }

    private init(
        home: String,
        sessionID: UUID,
        socketPath: String,
        lockPath: String,
        stderrPath: String,
        holderPID: Int32,
        spawnerExitStatus: Int32?
    ) {
        self.home = home
        self.sessionID = sessionID
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.stderrPath = stderrPath
        self.holderPID = holderPID
        self.spawnerExitStatus = spawnerExitStatus
    }

    /// Waits for the socket FILE, which `bind()` creates before the holder
    /// calls `listen()`. It does not mean the holder is accepting; `connect`
    /// covers that gap.
    func waitForSocket(timeout: TimeInterval = TestDeadlines.saturatedPassSeconds) async {
        await waitUntil("the holder socket at \(socketPath)\n\(diagnostics())", timeout: timeout) {
            FileManager.default.fileExists(atPath: socketPath)
        }
    }

    /// Connects once the holder is accepting connections, not merely once its
    /// socket file exists.
    ///
    /// The holder `bind()`s, which creates the file `waitForSocket` sees, and
    /// only then `listen()`s. On Darwin a `connect` that lands between the two
    /// is refused at once with ECONNREFUSED (errno 61) instead of queueing, and
    /// so is one that finds the listen backlog full. That gap is in the holder
    /// process and widens on a loaded runner, so a refusal is retried — and
    /// only a refusal: a refused connect never reaches the holder's `accept`,
    /// so a retry cannot leave a stray client behind. Every other error is
    /// thrown at once, and so is a refusal from a holder that is no longer
    /// alive, since a dead holder can never start listening. Every error thrown
    /// here carries the holder's log.
    ///
    /// The attempts run inside `waitUntil`, so they share its pace, its
    /// deadline and its cancellation handling. When the deadline runs out,
    /// `waitUntil` records its own timeout first, as it does for `start`'s pid
    /// wait, and the error thrown here adds the attempt count.
    func connect(
        receiveTimeout: TimeInterval = 5.0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TestHolderClient {
        let started = ContinuousClock.now
        var attempts = 0
        var client: TestHolderClient?
        var failure: (any Error)?
        let settled = await waitUntil(
            "the holder at \(socketPath) to accept a connection\n\(diagnostics())",
            sourceLocation: sourceLocation
        ) {
            attempts += 1
            do {
                client = try connectOnce(receiveTimeout: receiveTimeout)
                return true
            } catch TestHolderError.connectFailed(_, let code) where code == ECONNREFUSED {
                return !processIsAlive(holderPID)
            } catch {
                failure = error
                return true
            }
        }
        if let client { return client }
        if let failure {
            throw TestHolderError.connectFailedWithHolderLog(underlying: failure, diagnostics: diagnostics())
        }
        if settled {
            // Settled with neither a client nor another error: the last
            // attempt was refused by a holder that had exited.
            throw TestHolderError.holderExitedWhileRefusing(
                path: socketPath, refusedAttempts: attempts, diagnostics: diagnostics())
        }
        // `waitUntil` returns false both when the harness cancelled the test
        // and when the deadline ran out; only the second is this call's failure.
        try Task.checkCancellation()
        throw TestHolderError.connectRefusedUntilDeadline(
            path: socketPath,
            refusedAttempts: attempts,
            elapsed: ContinuousClock.now - started,
            diagnostics: diagnostics())
    }

    /// One connect attempt, with no retry: what `connect` repeats, and what
    /// `tearDown` uses directly, since it runs from a `defer` and cannot
    /// suspend.
    private func connectOnce(receiveTimeout: TimeInterval) throws -> TestHolderClient {
        try TestHolderClient(socketPath: socketPath, receiveTimeout: receiveTimeout)
    }

    /// Remember a job pid so teardown can reclaim it. Holder death is not child
    /// death, so anything a test learns about the job has to be recorded here.
    func trackChild(_ pid: Int32) {
        if pid > 0 { trackedChildPID = pid }
    }

    func diagnostics() -> String {
        (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "<no holder output>"
    }

    /// Kills the holder AND the job, in that order, then removes the scratch
    /// root. Idempotent, so a test may terminate the holder mid-body and still
    /// call this from its `defer`.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        // Last chance to learn the job pid: a test that never described the
        // child would otherwise leave a `sleep` behind.
        if trackedChildPID == 0, processIsAlive(holderPID),
           let client = try? connectOnce(receiveTimeout: 1.0) {
            if case .described(let description)? = try? client.request(.describe) {
                trackedChildPID = description.childPID
            }
            client.close()
        }

        if processIsAlive(holderPID) { kill(holderPID, SIGKILL) }
        if processIsAlive(trackedChildPID) { kill(trackedChildPID, SIGKILL) }
        // Neither is our child, so nothing here can `waitpid`; the kernel
        // reparents and reaps them. Confirm they are gone so a leak fails the
        // test that caused it rather than the next run.
        blockingWaitUntil("the holder and its job to disappear", timeout: 5.0) {
            !processIsAlive(holderPID) && !processIsAlive(trackedChildPID)
        }
        try? FileManager.default.removeItem(atPath: home)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A minimal client for the holder's `[UInt32 LE length][JSON]` protocol.
///
/// `SO_RCVTIMEO` is what keeps a wedged holder from hanging the suite: a
/// receive that times out surfaces as a thrown error attributed to the test.
final class TestHolderClient {
    private var fd: Int32
    private var inbox = Data()
    private var pending: [HolderResponse] = []

    init(socketPath: String, receiveTimeout: TimeInterval = 5.0) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestHolderError.connectFailed(path: socketPath, errno: errno) }

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
        let connected = withUnsafePointer(to: &address) { addressPtr in
            addressPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let saved = errno
            Darwin.close(fd)
            fd = -1
            throw TestHolderError.connectFailed(path: socketPath, errno: saved)
        }

        setReceiveTimeout(receiveTimeout)
        // A holder that has already reported an exit closes as soon as it has,
        // so a write can legitimately land on a socket whose peer is gone.
        // Without this that write raises SIGPIPE, whose default disposition
        // would kill the TEST RUNNER — every suite in the process, with no
        // failure attributed to anything.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Re-arms `SO_RCVTIMEO`, so one connection can wait out a short silence
    /// probe and then give the answer to a real request the ordinary budget.
    func setReceiveTimeout(_ seconds: TimeInterval) {
        let whole = Int(seconds)
        var timeout = timeval(
            tv_sec: whole,
            tv_usec: suseconds_t((seconds - TimeInterval(whole)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends one `describe` and then reads until the holder reports a status
    /// that is not `.alive`.
    ///
    /// Tolerates both orderings, which is not cosmetic: a job that exits
    /// promptly may already be reaped by the time this client connects, in
    /// which case the holder pushes the terminal status at accept time and
    /// never reads the request. Bounded by `SO_RCVTIMEO` — a status that never
    /// arrives throws rather than hanging.
    func awaitTerminalStatus() throws -> HolderChildDescription {
        try? send(.describe)
        while true {
            guard case .described(let description) = try receive() else { continue }
            if description.status != .alive { return description }
        }
    }

    func send(_ request: HolderRequest) throws {
        try FDChannel.sendData(HolderFraming.frame(request), over: fd)
    }

    /// Waits out the connection's receive timeout and reports whatever the
    /// holder said without being asked — `nil` for the silence a client that
    /// has issued no request is owed.
    ///
    /// Silence and a closed connection stay distinct on purpose. A holder that
    /// greeted this client and hung up would satisfy "nothing more arrives"
    /// while being exactly the failure the probe exists to catch, so the EOF
    /// throws rather than reading as quiet.
    func frameArrivingUnsolicited() throws -> HolderResponse? {
        do {
            return try receive()
        } catch FDChannelError.receiveFailed(let code) where code == EAGAIN {
            return nil
        }
    }

    /// Reads the next framed response, along with any descriptors that rode
    /// with it.
    /// One `recvmsg` can carry several frames — the holder answers a request
    /// and pushes an exit report microseconds apart — so decoded-but-unreturned
    /// frames are QUEUED, never dropped. Returning `drain(…).first` and
    /// discarding the rest loses the second frame, and since the holder closes
    /// right after reporting an exit, the next read then sees EOF: the caller
    /// gets `peerClosed` for a report that did arrive. That was a real,
    /// load-dependent flake in this suite, not a hypothetical.
    func receiveWithFDs() throws -> (HolderResponse, [Int32]) {
        var fds: [Int32] = []
        while true {
            if !pending.isEmpty {
                return (pending.removeFirst(), fds)
            }
            pending = try HolderFraming.drain(HolderResponse.self, from: &inbox)
            if !pending.isEmpty { continue }
            let message = try FDChannel.receiveMessage(from: fd, capacity: 4096)
            fds.append(contentsOf: message.fds)
            inbox.append(message.data)
        }
    }

    func receive() throws -> HolderResponse {
        let (response, fds) = try receiveWithFDs()
        for descriptor in fds { Darwin.close(descriptor) }
        return response
    }

    func request(_ request: HolderRequest) throws -> HolderResponse {
        try send(request)
        return try receive()
    }

    func requestWithFDs(_ request: HolderRequest) throws -> (HolderResponse, [Int32]) {
        try send(request)
        return try receiveWithFDs()
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}
