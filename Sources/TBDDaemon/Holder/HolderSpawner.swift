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
///      handshaken.
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

    // MARK: - Spawn

    func spawn(
        sessionID: UUID,
        launch: HolderLaunchRequest,
        owner: HolderOwnerToken,
        environment: [String: String]
    ) async throws -> HolderHandle {
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

        let stderrPath = holdersDir.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).log").path
        let holderPID = try launchHolder(
            sessionID: sessionID,
            socketPath: socketPath,
            stderrPath: stderrPath,
            launch: launch,
            owner: owner,
            environment: environment,
            lock: lock)

        // The holder now owns the lock through its own copy of the open file
        // description. Dropping ours makes it the sole owner, which is what
        // makes the kernel release the lock exactly when the holder dies.
        lock.release()
        lockReleased = true

        let description: HolderChildDescription
        do {
            description = try await awaitBinding(socketPath: socketPath)
        } catch {
            throw resolveUnreachableHolder(
                holderPID: holderPID,
                sessionID: sessionID,
                socketPath: socketPath,
                stderrPath: stderrPath,
                cause: error)
        }

        Self.logger.info(
            """
            spawned holder pid \(holderPID, privacy: .public) for session \
            \(sessionID.uuidString, privacy: .public): child \
            \(description.childPID, privacy: .public) on \(description.ttyName, privacy: .public)
            """)
        return HolderHandle(
            holderPID: holderPID, childPID: description.childPID, socketPath: socketPath)
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
        cause: Swift.Error
    ) -> Swift.Error {
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let diagnostics = (try? String(contentsOfFile: stderrPath, encoding: .utf8))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "<no holder output>"

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
            \(cause.localizedDescription, privacy: .public)
            """)
        kill(holderPID, SIGKILL)
        // Reaped because the holder is the daemon's own child: without this the
        // corpse accumulates in its process table.
        var ignored: Int32 = 0
        _ = waitpid(holderPID, &ignored, 0)
        return Error.holderDidNotBind(
            holderPID: holderPID, socketPath: socketPath, diagnostics: diagnostics)
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

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
    /// clock.
    ///
    /// Elapsed time is accumulated from the poll interval rather than measured
    /// against a deadline because `any Clock<Duration>` pins `Duration` but not
    /// `Instant`: instant arithmetic does not typecheck through the
    /// existential, and a limit expressed as "how much waiting has been spent"
    /// is what a fake clock can drive.
    private func awaitBinding(socketPath: String) async throws -> HolderChildDescription {
        var waited: Duration = .zero
        while true {
            let client = HolderClient(socketPath: socketPath, receiveTimeout: handshakeTimeout)
            do {
                let description = try await client.describe()
                await client.close()
                return description
            } catch HolderClient.Error.rejected(let version) {
                await client.close()
                throw Error.rejected(version: version)
            } catch {
                await client.close()
            }

            guard waited < bindTimeout else { break }
            try? await clock.sleep(for: bindPollInterval)
            waited += bindPollInterval
        }

        throw BindBudgetExhausted(budget: bindTimeout)
    }

    /// The budget ran out with no answer. Never escapes `spawn`: what a caller
    /// sees is whichever error `resolveUnreachableHolder` chooses once it knows
    /// whether the holder ever created its socket — the two outcomes differ in
    /// whether a job can exist, which this type deliberately cannot know. It
    /// still carries a real description, because it is logged as the cause of
    /// whichever of those two the spawn fails with.
    private struct BindBudgetExhausted: LocalizedError {
        let budget: Duration

        var errorDescription: String? {
            "no answer within the \(budget) bind budget"
        }
    }
}
