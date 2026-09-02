import Darwin
import Foundation
import TBDShared
import os

/// A live holder, and everything the daemon needs to find it again.
///
/// `holderPID` is the supervisor; `childPID` is the job it `forkpty`'d. They
/// are deliberately separate facts: holder death is **not** child death, and
/// treating one pid as a proxy for the other is how a reclaimer ends up killing
/// the wrong process or believing a session ended when only its supervisor did.
struct HolderHandle: Sendable, Equatable {
    var holderPID: Int32
    var childPID: Int32
    var socketPath: String
}

/// A spawned holder, together with **the connection its handshake ran on**.
///
/// The connection is returned rather than closed because the holder serves one
/// client at a time and learns the previous one has gone only when its `poll`
/// loop next reads EOF on that socket. A spawner that closed its handshake
/// connection and returned would leave every caller to reconnect into that
/// window, where the holder legitimately answers the busy sentinel for a slot
/// that is already free. Handing the live connection on removes the reconnect,
/// so the window cannot be entered: the caller attaches over the connection the
/// handshake already proved good, and pays one fewer connect per session.
///
/// **Ownership is the client's, and it is released by letting go.** `client` is
/// an actor whose `deinit` closes the socket, so a caller that never uses it
/// frees the holder's client slot by dropping the result; a caller that wants
/// the slot free sooner calls `close()`, and the client reconnects on its next
/// verb like any other. Nothing is returned on a failed spawn — every
/// connection the spawner opened on the way to one is closed before it throws.
struct HolderSpawnResult: Sendable {
    var handle: HolderHandle
    var client: HolderClient
}

/// Spawns one holder process per session and waits for it to become reachable.
///
/// The ordering in `spawn` is the contract rather than a preference, and each
/// step closes a hazard the previous one cannot:
///
///   1. The rendezvous directory must exist before anything is created in it.
///   2. The creation lock is taken **before** the socket path is examined. A
///      spawner that cannot take it has learned a live holder owns this UUID
///      without connecting, and must back off rather than clear the path.
///   3. A socket with no sibling lock file is *unowned-but-unproven*, never
///      unowned: it is probed, and only a connect that fails outright licenses
///      unlinking it.
///   4. The lock travels to the holder as a **descriptor number**, placed by a
///      `posix_spawn` `dup2` file action.
///   5. The holder's stdio is detached, with stderr somewhere retrievable.
///   6. The daemon drops its own copy of the lock, so the holder alone holds it
///      and the kernel drops it when the holder dies.
///   7. The socket is polled for reachability on the injected clock, then
///      handshaken — and the connection that answered is **returned, not
///      closed**, because a caller made to reconnect would race the holder's
///      notice that the handshake connection went away. See
///      `HolderSpawnResult`.
///   8. A holder that never answers is judged by whether its socket exists,
///      never by the handshake alone: no socket means it never bound and so
///      never forked, which is the only state where killing it can orphan
///      nothing. See `resolveUnreachableHolder`.
///
/// **Who reclaims a holder is not answered here.** The holder is spawned as a
/// direct child of the daemon, so a daemon that outlives it must reap its exit
/// status, and a holder orphaned by a daemon crash is reclaimed by nothing
/// today. Both belong to the reconcilers Milestone B adds (the
/// `WorktreeLifecycle+Reconcile` holder inventory, the `OrphanGC` socket and
/// lock sweep, and the `AgentReaper` holder-transport leg); until they land the
/// flag stays off outside a development machine.
struct HolderSpawner {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    /// The descriptor number the creation lock is placed on in the holder.
    ///
    /// Any number above stdio works — `forkpty` dup2s the pty slave onto 0/1/2
    /// in the job, so a lock parked there would be silently overwritten — and
    /// the holder validates that it landed above 2.
    static let lockDescriptorNumber: Int32 = 9

    /// How long to wait for a freshly spawned holder to bind and answer.
    /// Generous because it covers a cold `execve` of a debug binary under a
    /// loaded machine, and bounded because a holder that never binds must fail
    /// the spawn rather than wedge the caller.
    static let defaultBindTimeout: Duration = .seconds(10)
    static let defaultBindPollInterval: Duration = .milliseconds(20)
    /// How long one handshake attempt against a socket that already exists may
    /// wait. Separate from `bindTimeout`, which bounds the whole wait: a
    /// connect that succeeds and then goes quiet must not spend the entire
    /// startup budget on a single attempt.
    static let defaultHandshakeTimeout: Duration = .seconds(2)

    enum Error: LocalizedError, Equatable {
        /// Another live holder owns this session UUID. Nothing was created and,
        /// crucially, nothing was cleared.
        case lockHeldByLiveHolder(sessionID: UUID, lockPath: String)
        /// The holder never created its socket within the budget, and was
        /// therefore killed. Carries whatever it wrote to stderr, which is the
        /// only channel for anything that went wrong before the socket existed.
        case holderDidNotBind(holderPID: Int32, socketPath: String, diagnostics: String)
        /// The holder created its socket but never answered the handshake.
        ///
        /// **It is deliberately left running.** Binding happens before
        /// `forkpty`, so a holder that got this far may already be supervising
        /// a live job — one recorded in no database, which nothing would ever
        /// find again if the holder were killed here. The pid and the socket
        /// path are carried so a human, or a later reconciler, can.
        case holderBoundButUnresponsive(holderPID: Int32, socketPath: String, diagnostics: String)
        /// The holder answered the handshake with the busy sentinel.
        case rejected(version: Int)
        case rendezvousDirectoryUnavailable(path: String, detail: String)
        case lockUnavailable(path: String, detail: String)
        case spawnFailed(executable: String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .lockHeldByLiveHolder(let sessionID, let lockPath):
                return "a live holder already owns session \(sessionID.uuidString) "
                    + "(creation lock at \(lockPath)); refusing to clear its socket"
            case .holderDidNotBind(let holderPID, let socketPath, let diagnostics):
                return "the holder never created \(socketPath) within the budget, so pid "
                    + "\(holderPID) was killed before it could fork a job. "
                    + "Holder output: \(diagnostics)"
            case .holderBoundButUnresponsive(let holderPID, let socketPath, let diagnostics):
                return "the holder bound \(socketPath) but never answered the handshake. "
                    + "Pid \(holderPID) was left running because it may already own a live "
                    + "job; kill it by hand once you have checked. Holder output: \(diagnostics)"
            case .rejected(let version):
                return "the freshly spawned holder rejected the handshake "
                    + "(protocol version \(version))"
            case .rendezvousDirectoryUnavailable(let path, let detail):
                return "could not create the holder rendezvous directory \(path): \(detail)"
            case .lockUnavailable(let path, let detail):
                return "could not take the holder creation lock at \(path): \(detail)"
            case .spawnFailed(let executable, let code):
                return "could not spawn \(executable): "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    let executableURL: URL
    let bindTimeout: Duration
    let bindPollInterval: Duration
    let handshakeTimeout: Duration
    private let clock: any Clock<Duration>

    init(
        executableURL: URL,
        bindTimeout: Duration = HolderSpawner.defaultBindTimeout,
        bindPollInterval: Duration = HolderSpawner.defaultBindPollInterval,
        handshakeTimeout: Duration = HolderSpawner.defaultHandshakeTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executableURL = executableURL
        self.bindTimeout = bindTimeout
        self.bindPollInterval = bindPollInterval
        self.handshakeTimeout = handshakeTimeout
        self.clock = clock
    }

    // MARK: - Finding the binary

    /// The `TBDHolder` binary, as a **sibling of the running daemon**.
    ///
    /// Sibling, and nothing else: `TBDHolder` is a product of the same package
    /// as `TBDDaemon`, so every layout that has one has the other beside it —
    /// `.build/debug` when `scripts/restart.sh` launches the daemon, and any
    /// install layout that stages the daemon at all. `PATH` is deliberately not
    /// consulted: a holder is a supervisor for this daemon's own sessions, and
    /// resolving it through the user's `PATH` would let an unrelated binary of
    /// the same name own them.
    ///
    /// `nil` when no such file exists, which the registry reports by name
    /// rather than treating as a spawn failure — the difference between "the
    /// build is incomplete" and "the holder crashed" is worth keeping.
    static func locateSiblingExecutable(
        of daemonExecutable: URL? = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    ) -> URL? {
        guard let daemonExecutable else { return nil }
        let candidate = daemonExecutable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("TBDHolder")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            Self.logger.error(
                """
                no TBDHolder binary beside the running daemon at \
                \(candidate.path, privacy: .public); the holder transport cannot spawn
                """)
            return nil
        }
        return candidate
    }

    // MARK: - Spawn

    func spawn(
        sessionID: UUID,
        launch: HolderLaunchRequest,
        owner: HolderOwnerToken,
        environment: [String: String]
    ) async throws -> HolderSpawnResult {
        let socketPath = try HolderRendezvous.socketPath(sessionID: sessionID, environment: environment)
        let lockPath = try HolderRendezvous.lockPath(sessionID: sessionID, environment: environment)
        let holdersDir = TBDConstants.holdersDir(environment: environment)

        do {
            try FileManager.default.createDirectory(
                at: holdersDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw Error.rendezvousDirectoryUnavailable(
                path: holdersDir.path, detail: error.localizedDescription)
        }

        // Read BEFORE acquiring: `HolderLock.acquire` creates the file, so
        // asking afterwards can only ever answer "yes" and the
        // socket-without-a-lock case would become unreachable.
        let lockFileExisted = FileManager.default.fileExists(atPath: lockPath)

        let lock: HolderLock
        do {
            lock = try HolderLock.acquire(path: lockPath)
        } catch HolderLock.Error.alreadyHeld {
            // Deliberately nothing else: not a probe, not an unlink, not a
            // stat. The lock is the proof, and a spawner that goes on to touch
            // the socket here is the exact hazard the lock exists to prevent.
            throw Error.lockHeldByLiveHolder(sessionID: sessionID, lockPath: lockPath)
        } catch {
            throw Error.lockUnavailable(path: lockPath, detail: error.localizedDescription)
        }
        var lockReleased = false
        defer { if !lockReleased { lock.release() } }

        if !lockFileExisted, FileManager.default.fileExists(atPath: socketPath) {
            // Absence of a lock is not evidence of absence of a holder — the
            // file could have been swept, or written by a layout we do not
            // recognise. Ask the socket itself.
            if await someoneIsListening(at: socketPath) {
                throw Error.lockHeldByLiveHolder(sessionID: sessionID, lockPath: lockPath)
            }
            unlink(socketPath)
        }

        let stderrPath = HolderRendezvous.logPath(
            sessionID: sessionID, environment: environment)
        let holderPID = try launchHolder(
            sessionID: sessionID,
            socketPath: socketPath,
            stderrPath: stderrPath,
            launch: launch,
            owner: owner,
            environment: environment,
            lock: lock)
        // Read once, here, so a failure can say how long the holder had between
        // `posix_spawn` returning and the kernel first admitting it exists.
        // Data, not behavior — nothing branches on it.
        let spawnReturnedAt = Date()

        // The holder now owns the lock through its own copy of the open file
        // description. Dropping ours makes it the sole owner, which is what
        // makes the kernel release the lock exactly when the holder dies.
        lock.release()
        lockReleased = true

        let attached: (description: HolderChildDescription, client: HolderClient)
        do {
            attached = try await awaitBinding(socketPath: socketPath)
        } catch {
            throw resolveUnreachableHolder(
                holderPID: holderPID,
                sessionID: sessionID,
                socketPath: socketPath,
                stderrPath: stderrPath,
                spawnReturnedAt: spawnReturnedAt,
                cause: error)
        }

        let description = attached.description
        Self.logger.info(
            """
            spawned holder pid \(holderPID, privacy: .public) for session \
            \(sessionID.uuidString, privacy: .public): child \
            \(description.childPID, privacy: .public) on \(description.ttyName, privacy: .public)
            """)
        return HolderSpawnResult(
            handle: HolderHandle(
                holderPID: holderPID, childPID: description.childPID, socketPath: socketPath),
            client: attached.client)
    }

    // MARK: - A holder that was spawned but never answered

    /// Decides what to do with a spawned holder that never completed a
    /// handshake, and returns the error the spawn fails with.
    ///
    /// **The kill is gated on evidence that no job can exist, not on the
    /// handshake having failed.** `Holder.run()` binds and listens *before* it
    /// `forkpty`s, and it only ever `accept`s from inside `serve()`, which runs
    /// after the fork. So a socket that was never created is proof the holder
    /// never reached bind and therefore never forked a job: nothing can be
    /// orphaned by killing it, and leaving it alive would strand the creation
    /// lock it holds. That, and only that, licenses SIGKILL.
    ///
    /// A socket that *does* exist says the opposite — the holder got at least
    /// as far as bind, and the very case the generous budget exists for (a
    /// loaded machine, a cold `execve`) is the case where it has since forked a
    /// job that is recorded in no database. Milestone A has no holder
    /// reconciler, so killing the holder there would orphan that job
    /// permanently and destroy the only evidence of it. It is left running and
    /// named instead: the spawn still fails, this session UUID stays locked
    /// until somebody deals with the pid, and that is a visible, recoverable
    /// state rather than a silent leak.
    ///
    /// The residual window is the microseconds between the holder's bind and
    /// its fork, and the check is read at the moment of the decision — a holder
    /// that creates its socket after this stat has already missed the whole
    /// budget.
    private func resolveUnreachableHolder(
        holderPID: Int32,
        sessionID: UUID,
        socketPath: String,
        stderrPath: String,
        spawnReturnedAt: Date,
        cause: Swift.Error
    ) -> Swift.Error {
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        // Observed BEFORE anything is killed, because the kill destroys the
        // evidence: after it, every failure looks like a holder that died, and
        // "crashed on its own" and "was put down by this function" are the two
        // states most worth telling apart.
        let liveness = Self.observeHolder(holderPID)
        let diagnostics = Self.describeFailure(
            holderPID: holderPID,
            liveness: liveness,
            socketPath: socketPath,
            socketExists: socketExists,
            stderrPath: stderrPath,
            spawnReturnedAt: spawnReturnedAt,
            cause: cause)

        guard !socketExists else {
            Self.logger.error(
                """
                holder pid \(holderPID, privacy: .public) for session \
                \(sessionID.uuidString, privacy: .public) bound \(socketPath, privacy: .public) but \
                never answered; leaving it alive because it may already own a job: \
                \(cause.localizedDescription, privacy: .public)
                """)
            // A busy holder answered — with the sentinel, but it answered — so
            // that failure keeps its own name rather than being reported as
            // silence.
            if let spawnerError = cause as? Error, case .rejected = spawnerError {
                return spawnerError
            }
            return Error.holderBoundButUnresponsive(
                holderPID: holderPID, socketPath: socketPath, diagnostics: diagnostics)
        }

        Self.logger.error(
            """
            holder pid \(holderPID, privacy: .public) for session \
            \(sessionID.uuidString, privacy: .public) never created \
            \(socketPath, privacy: .public), so it never forked a job; killing it: \
            \(cause.localizedDescription, privacy: .public). \(diagnostics, privacy: .public)
            """)
        // Only a holder that is still running needs killing, and `observeHolder`
        // has already reaped one that is not: signalling and waiting on a pid
        // that has been collected is at best a no-op and at worst aimed at
        // whatever inherited that number.
        if case .alive = liveness {
            kill(holderPID, SIGKILL)
            // Reaped because the holder is the daemon's own child: without this
            // the corpse accumulates in its process table.
            var ignored: Int32 = 0
            _ = waitpid(holderPID, &ignored, 0)
        }
        return Error.holderDidNotBind(
            holderPID: holderPID, socketPath: socketPath, diagnostics: diagnostics)
    }

    // MARK: - Describing a holder that did not answer

    /// What the kernel says about a spawned holder at the moment the budget ran
    /// out.
    ///
    /// The distinction this exists to preserve is `alive` versus everything
    /// else. A holder that is **alive** and has not bound is stuck — in `exec`,
    /// in dyld, in its own startup — and the fix is on that path. A holder that
    /// **exited** chose to, and its code says why. A holder that was
    /// **signalled** was killed by something outside itself, which on a
    /// saturated machine is usually the kernel, and no amount of budget would
    /// have saved it. Reporting "no holder output" for all three, as this used
    /// to, makes the three indistinguishable and the failure unfixable.
    private enum HolderLiveness {
        case alive
        case exited(code: Int32)
        case signalled(signal: Int32)
        /// `waitpid` refused: the pid is not (or is no longer) our child.
        case notOurChild(errno: Int32)

        var summary: String {
            switch self {
            case .alive: return "alive"
            case .exited(let code): return "exited(\(code))"
            case .signalled(let signal):
                return "killed by signal \(signal) (\(String(cString: strsignal(signal))))"
            case .notOurChild(let code):
                return "not our child (waitpid errno \(code))"
            }
        }
    }

    /// Reaps `pid` if it has already exited, and reports which of the four
    /// states it is in. `WNOHANG`, so a live holder is left running for the
    /// caller to decide about.
    private static func observeHolder(_ pid: Int32) -> HolderLiveness {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid {
            if _WSTATUS(status) == 0 {
                return .exited(code: (status >> 8) & 0xff)
            }
            return .signalled(signal: _WSTATUS(status))
        }
        if reaped == 0 { return .alive }
        return .notOurChild(errno: errno)
    }

    /// `_WSTATUS` is a macro, so it does not survive into Swift; this is the
    /// same seven-bit field `sys/wait.h` reads.
    private static func _WSTATUS(_ status: Int32) -> Int32 { status & 0o177 }

    /// The kernel's own view of a process: which run state it is in, and when
    /// it started.
    ///
    /// `SIDL` is the one worth naming — a process the kernel has created but
    /// which has not begun executing its image is stuck in `exec`, not stuck in
    /// its own code, and that is a completely different bug from a holder that
    /// reached `main` and blocked.
    private static func kernelView(of pid: Int32) -> (state: String, startedAt: Date?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        // Spelled as literals rather than the `SIDL`/`SRUN`/… macros from
        // `sys/proc.h`, which are not guaranteed to survive the importer.
        let state: String
        switch Int32(info.kp_proc.p_stat) {
        case 1: state = "SIDL (created, not yet executing)"
        case 2: state = "SRUN (runnable)"
        case 3: state = "SSLEEP (blocked)"
        case 4: state = "SSTOP (stopped)"
        case 5: state = "SZOMB (exited, unreaped)"
        default: state = "p_stat \(info.kp_proc.p_stat)"
        }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = started.tv_sec > 0
            ? Date(timeIntervalSince1970:
                TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
            : nil
        return (state, startedAt)
    }

    /// Everything known about a holder that never answered, in one line per
    /// fact.
    ///
    /// It exists because `"<no holder output>"` was the whole diagnostic, and
    /// an empty stderr file is the *same observation* as a crashed process, a
    /// wedged process, and a redirect that never applied. Each field below
    /// separates a pair those three collapsed:
    ///
    ///   - `holder` separates crashed from stuck, and self-inflicted from killed.
    ///   - `kernel` separates stuck-in-exec from stuck-in-our-own-code.
    ///   - `stderr` separates "wrote nothing" from "there was nowhere to write":
    ///     a missing file means the redirect is the bug, an existing empty one
    ///     means the holder genuinely said nothing.
    ///   - `rendezvous` separates "never created the socket" from "created it
    ///     somewhere we were not looking".
    ///   - `wait` says how much real time the budget bought, which is the only
    ///     way to tell an impatient poller from a holder that had long enough.
    private static func describeFailure(
        holderPID: Int32,
        liveness: HolderLiveness,
        socketPath: String,
        socketExists: Bool,
        stderrPath: String,
        spawnReturnedAt: Date,
        cause: Swift.Error
    ) -> String {
        var fields: [String] = ["holder=\(liveness.summary)"]

        if let view = kernelView(of: holderPID) {
            var kernel = "kernel=\(view.state)"
            if let startedAt = view.startedAt {
                let delta = startedAt.timeIntervalSince(spawnReturnedAt)
                kernel += String(format: ", started %+.3fs relative to posix_spawn", delta)
            }
            fields.append(kernel)
        } else {
            fields.append("kernel=<no such process>")
        }

        let stderrURL = URL(fileURLWithPath: stderrPath)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: stderrPath) {
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let text = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            fields.append(
                text.isEmpty
                    ? "stderr=<file exists, \(size) bytes, empty: the holder wrote nothing>"
                    : "stderr=\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            fields.append("stderr=<file missing at \(stderrPath): the redirect never applied>")
        }

        let directory = stderrURL.deletingLastPathComponent().path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .sorted()
            .joined(separator: ", ")
        fields.append(
            "rendezvous=socket \(socketExists ? "present" : "absent") "
                + "at \(socketPath); \(directory) holds [\(entries ?? "<unreadable>")]")

        fields.append("wait=\(cause.localizedDescription)")
        return fields.joined(separator: "; ")
    }

    // MARK: - Probing an existing socket

    /// Whether something answers at `socketPath`.
    ///
    /// A successful handshake and a rejection both mean "back off": one is a
    /// live holder serving somebody, the other is a live holder that is busy.
    /// So does a connect that fails for any reason other than "nothing is
    /// listening" — an unreadable socket is not a dead one. Only
    /// `ECONNREFUSED` (a bound path whose server is gone) and `ENOENT` (the
    /// path vanished under us) license unlinking.
    private func someoneIsListening(at socketPath: String) async -> Bool {
        let client = HolderClient(socketPath: socketPath, receiveTimeout: Self.probeTimeout)
        let answer: Bool
        do {
            _ = try await client.describe()
            answer = true
        } catch HolderClient.Error.rejected {
            answer = true
        } catch HolderClient.Error.cannotConnect(_, let code) {
            answer = !(code == ECONNREFUSED || code == ENOENT)
        } catch {
            // Connected but did not answer, or answered nonsense. Something has
            // that path open; leave it alone.
            answer = true
        }
        await client.close()
        return answer
    }

    /// Bound separately from `bindTimeout`: probing an unknown socket is not
    /// waiting for our own holder to start, and a stranger that connects but
    /// never answers must not stretch a spawn by the full startup budget.
    private static let probeTimeout: Duration = .seconds(2)

    // MARK: - Launching

    private func launchHolder(
        sessionID: UUID,
        socketPath: String,
        stderrPath: String,
        launch: HolderLaunchRequest,
        owner: HolderOwnerToken,
        environment: [String: String],
        lock: HolderLock
    ) throws -> Int32 {
        let payload = try JSONEncoder().encode(launch).base64EncodedString()
        let arguments = [
            executableURL.path,
            "--session", sessionID.uuidString,
            "--socket", socketPath,
            "--lock-fd", String(Self.lockDescriptorNumber),
            "--launch", payload,
            "--owner", owner.rawValue,
        ]

        // `</dev/null` and a real file for stdout/stderr, never inherited
        // descriptors. A holder that inherits the daemon's stdout holds that
        // pipe open for the whole session's life, so whatever reads it never
        // sees EOF — measured while driving the binary by hand, where it looked
        // exactly like a protocol hang. stderr must still go somewhere
        // retrievable: it is the daemon's only channel for anything that went
        // wrong before the socket existed.
        let nullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let logFD = open(stderrPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        defer {
            if nullFD >= 0 { close(nullFD) }
            if logFD >= 0 { close(logFD) }
        }
        guard nullFD >= 0, logFD >= 0 else {
            throw Error.spawnFailed(executable: executableURL.path, errno: errno)
        }

        // The lock is relocated above the target number rather than passed
        // where it sits, because `dup2(fd, fd)` succeeds WITHOUT clearing
        // `FD_CLOEXEC`: a lock that already occupied the target would be closed
        // at exec and the holder would refuse to start. `F_DUPFD_CLOEXEC`
        // guarantees a number above the target in one call, and keeps the
        // duplicate close-on-exec in *this* process — which is the whole reason
        // this uses a dup2 file action rather than
        // `HolderLock.makeInheritableAcrossExec()`. Clearing `FD_CLOEXEC` on
        // the daemon's own descriptor would expose the lock to every other
        // concurrent `posix_spawn` in the daemon, and an unrelated child that
        // inherited it would hold this session UUID unreclaimable until it
        // died.
        let lockSource = fcntl(lock.fileDescriptor, F_DUPFD_CLOEXEC, Self.lockDescriptorNumber + 1)
        guard lockSource >= 0 else {
            throw Error.spawnFailed(executable: executableURL.path, errno: errno)
        }
        defer { close(lockSource) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // File actions run IN ORDER, and fd numbers collide. The stdio dup2s
        // come first and the lock's dup2 last, so that if the log or /dev/null
        // descriptor happens to land on the target number it has already been
        // copied to its final home by the time the lock overwrites it. There
        // are deliberately NO trailing closes: a close scheduled after the
        // lock's dup2 would destroy the descriptor it just placed.
        posix_spawn_file_actions_adddup2(&actions, nullFD, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_adddup2(&actions, lockSource, Self.lockDescriptorNumber)

        // Everything the daemon happens to have open without FD_CLOEXEC would
        // otherwise arrive in a process that outlives it. The four descriptors
        // above are named in file actions and survive; nothing else does.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // **A signal mask is inherited, and it survives `execve`.** This spawn
        // runs on whichever Swift-concurrency worker thread the enclosing task
        // landed on, and those run with nearly everything blocked — measured
        // here as SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP and SIGWINCH among
        // nineteen others. Without `SETSIGMASK` the holder inherits that mask,
        // its `forkpty` child inherits it in turn, and the job at the end of the
        // chain cannot be interrupted, suspended, hung up on, terminated by
        // anything short of SIGKILL, or told its terminal changed size. tmux
        // never showed this because the tmux server resets its own mask.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        // Dispositions are a separate inheritance: `SIG_IGN` survives `execve`
        // too, so anything the daemon ignores would arrive ignored. `SETSIGDEF`
        // starts the holder from defaults instead, and the holder then installs
        // the only two it actually wants — `SIGHUP` and `SIGPIPE` to `SIG_IGN`,
        // first thing in `Holder.run()`, which is what makes it survive this
        // daemon's death. Resetting here therefore takes nothing away from the
        // holder; it stops the daemon's incidental state reaching the job.
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)

        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        // Sorted purely so a holder's environment is reproducible in a log or a
        // crash report; the holder cannot observe the order.
        let envStrings: [String] = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var envp = envStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executableURL.path, &actions, &attributes, &argv, &envp)
        guard status == 0 else {
            throw Error.spawnFailed(executable: executableURL.path, errno: status)
        }
        return pid
    }

    // MARK: - Waiting for the rendezvous

    /// Polls until the socket answers a handshake, bounded on the **injected**
    /// clock, and returns the connection that answered.
    ///
    /// **The winning connection is kept open**, which is what makes the spawn
    /// hand-off raceless — see `HolderSpawnResult`. Every connection that did
    /// *not* answer is closed here, on both the retry and the rejection paths,
    /// so a failed spawn leaves nothing attached to the holder's one client
    /// slot.
    ///
    /// Elapsed time is accumulated from the poll interval rather than measured
    /// against a deadline because `any Clock<Duration>` pins `Duration` but not
    /// `Instant`: instant arithmetic does not typecheck through the
    /// existential, and a limit expressed as "how much waiting has been spent"
    /// is what a fake clock can drive.
    private func awaitBinding(
        socketPath: String
    ) async throws -> (description: HolderChildDescription, client: HolderClient) {
        var waited: Duration = .zero
        // Diagnostic only — nothing branches on either. The budget above is
        // credit spent on the injected clock; these two say what that credit
        // actually bought in real time, which is the one thing a CI failure
        // cannot be reasoned about without.
        var polls = 0
        var lastFailure: Swift.Error?
        let startedAt = Date()
        while true {
            let client = HolderClient(socketPath: socketPath, receiveTimeout: handshakeTimeout)
            do {
                let description = try await client.describe()
                // The handshake budget is a startup deadline, not a session
                // one, and this connection is about to become a session's.
                await client.adoptReceiveTimeout(HolderClient.defaultReceiveTimeout)
                return (description, client)
            } catch HolderClient.Error.rejected(let version) {
                await client.close()
                throw Error.rejected(version: version)
            } catch {
                lastFailure = error
                await client.close()
            }

            guard waited < bindTimeout else { break }
            polls += 1
            try? await clock.sleep(for: bindPollInterval)
            waited += bindPollInterval
        }

        throw BindBudgetExhausted(
            budget: bindTimeout,
            polls: polls,
            elapsed: Date().timeIntervalSince(startedAt),
            lastFailure: lastFailure)
    }

    /// The budget ran out with no answer. Never escapes `spawn`: what a caller
    /// sees is whichever error `resolveUnreachableHolder` chooses once it knows
    /// whether the holder ever created its socket — the two outcomes differ in
    /// whether a job can exist, which this type deliberately cannot know. It
    /// still carries a real description, because it is logged as the cause of
    /// whichever of those two the spawn fails with.
    ///
    /// `budget` is credit on the injected clock; `polls` and `elapsed` are what
    /// that credit cost in real time. They are reported together deliberately —
    /// the loop accumulates the *nominal* poll interval rather than measured
    /// time (see `awaitBinding`), so a budget of 10 s is really 500 attempts,
    /// and on a machine where each `sleep(for: 20ms)` resumes late those 500
    /// attempts can span minutes. Printing only the budget invites the wrong
    /// fix: raising a number that was never the unit of the wait.
    private struct BindBudgetExhausted: LocalizedError {
        let budget: Duration
        let polls: Int
        let elapsed: TimeInterval
        let lastFailure: Swift.Error?

        var errorDescription: String? {
            let last = lastFailure.map { "; last attempt: \($0.localizedDescription)" } ?? ""
            return String(
                format: "no answer after %d polls over %.1fs of real time "
                    + "(budget %@ of nominal poll interval)%@",
                polls, elapsed, String(describing: budget), last)
        }
    }
}
