import Darwin
import Foundation
import TBDShared
import os

/// Starts one `TBDModelProxy` for a TBD home and waits for it to say which
/// port it took.
///
/// The ordering is the contract, and it is the holder spawner's with the
/// socket swapped for a port (spec, "Rendezvous and identity"):
///
///   1. `<home>/proxy` must exist before anything is created in it. A home
///      that cannot be made usable fails here, before any process exists.
///   2. `proxy.lock` is taken **before the spawn**, so two daemons on one TBD
///      home cannot both mint a proxy, and a spawner that cannot take it has
///      learned a live proxy owns this home without connecting to it.
///   3. The lock travels to the child as a **descriptor number**, placed by a
///      `posix_spawn` `dup2` file action — the same mechanism, and for the
///      same reason, as `HolderSpawner`: `FD_CLOEXEC` is cleared on a
///      duplicate rather than on the daemon's own descriptor, so no unrelated
///      concurrent spawn in this process can inherit the lock.
///   4. The child's stdio is detached, with stdout and stderr in
///      `proxy.log` — the proxy's only channel for anything that goes wrong
///      before its logger is up.
///   5. The daemon drops its own copy of the lock right after `posix_spawn`,
///      so the child alone holds it and the kernel releases it when the child
///      dies.
///   6. The pid file is polled on the **injected clock** until it names *this
///      child* and a port. The pid match is what keeps a predecessor's file
///      from being read as this spawn's answer.
///
/// **Who reclaims a proxy is not answered here.** The proxy is spawned as a
/// direct child of the daemon and deliberately outlives it, exactly as a
/// holder does. `ModelProxySupervisor` owns the live one — it adopts, watches,
/// respawns and retires — and the `OrphanGC` leg sweeps the rendezvous files a
/// SIGKILLed proxy could not unlink. What this type guarantees on its own is
/// narrower and worth stating: **every proxy it starts and cannot finish
/// starting is killed and reaped before the throw**, so a failed spawn leaves
/// no process, and no lock, behind.
struct ModelProxySpawner: Sendable {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "model-proxy")

    /// The descriptor number the lock is placed on in the proxy, and the value
    /// of its `--lock-fd`. Above stdio, like the holder's, so the child's own
    /// redirections cannot overwrite it.
    static let lockDescriptorNumber: Int32 = 9

    /// The lowest number an inherited descriptor is relocated to. Above the
    /// target, because `dup2(fd, fd)` succeeds *without* clearing
    /// `FD_CLOEXEC`: a lock that already sat on the target would be closed at
    /// exec and the proxy would take its own lock — silently turning the
    /// hand-down into a no-op.
    private static var descriptorRelocationFloor: Int32 { lockDescriptorNumber + 1 }

    /// How long to wait for a freshly spawned proxy to bind and publish its
    /// port. Generous because it covers a cold `execve` of a debug binary on a
    /// loaded machine, and bounded because a proxy that never announces itself
    /// must fail the spawn rather than wedge the caller.
    static let defaultBindTimeout: Duration = .seconds(10)
    static let defaultBindPollInterval: Duration = .milliseconds(20)

    enum Error: LocalizedError, Equatable {
        /// A live proxy already holds `proxy.lock` for this home. **Nothing
        /// was spawned**, and nothing was cleared: the lock is the proof, and
        /// the right response is to probe the running proxy rather than to
        /// replace it.
        case lockHeld
        /// The proxy could not bind the port it was asked for. The supervisor
        /// probes `/tbd/status` on that port from here: a TBD proxy answering
        /// is adopted, anything else means the port is somebody else's and a
        /// fresh one is minted (spec, "Port").
        case bindFailed(port: Int)
        /// A directory under the home could not be created, or the lock file
        /// could not be opened for a reason other than contention. Respawning
        /// changes nothing until the filesystem is fixed.
        case homeUnusable
        /// `posix_spawn` itself refused. No child exists.
        case launchFailed(errno: Int32)
        /// The child neither published a port nor exited inside the budget. It
        /// was killed and reaped — see `killAndReap`.
        ///
        /// `polls` and `elapsed` are what that budget cost in real time, and
        /// they are carried rather than logged alone for `HolderSpawner`'s
        /// reason: the wait spends credit at the *nominal* poll interval
        /// rather than reading a clock, so a 10-second budget is really 500
        /// attempts, and on a runner where each `sleep(for: 20ms)` resumes
        /// late those attempts can span minutes. Without both numbers a CI log
        /// cannot tell a proxy that never bound from one that bound slowly,
        /// and the tempting fix is to raise a number that was never the unit
        /// of the wait.
        case bindTimeout(polls: Int, elapsed: TimeInterval)
        /// The child exited early with a status that is none of the above:
        /// a bad command line (2), a signal, or a crash. Carried rather than
        /// folded into `bindFailed` because respawning is the wrong answer to
        /// all three.
        case childExited(status: Int32)

        var errorDescription: String? {
            switch self {
            case .lockHeld:
                return "a live model proxy already holds the lock for this TBD home"
            case .bindFailed(let port):
                return "the model proxy could not bind port \(port)"
            case .homeUnusable:
                return "the model proxy's home could not be made usable"
            case .launchFailed(let code):
                return "could not spawn the model proxy: "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            case .bindTimeout(let polls, let elapsed):
                return String(
                    format: "the model proxy never published a port after %d polls over "
                        + "%.1fs of real time, and was killed",
                    polls, elapsed)
            case .childExited(let status):
                return "the model proxy exited with status \(status) before it published a port"
            }
        }
    }

    let executableURL: URL
    let bindTimeout: Duration
    let bindPollInterval: Duration
    /// The environment the proxy is spawned with. It reads its home from
    /// `--home` rather than from here, so this exists for the ordinary
    /// reasons a child needs one — and so a test can hand down an rc-free one.
    let environment: [String: String]
    private let clock: any Clock<Duration>

    init(
        executableURL: URL,
        bindTimeout: Duration = ModelProxySpawner.defaultBindTimeout,
        bindPollInterval: Duration = ModelProxySpawner.defaultBindPollInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.executableURL = executableURL
        self.bindTimeout = bindTimeout
        self.bindPollInterval = bindPollInterval
        self.environment = environment
        self.clock = clock
    }

    // MARK: - Finding the binary

    /// The `TBDModelProxy` binary, as a **sibling of the running daemon**.
    ///
    /// Sibling and nothing else, for the reason `HolderSpawner` gives: the
    /// proxy is a product of this package, so every layout that stages the
    /// daemon stages it too, and resolving it through `PATH` would let an
    /// unrelated binary of the same name own this home's sessions.
    ///
    /// It is also the file whose `ModelProxyVersion.identity` the supervisor
    /// compares against a running proxy's reported version, so "the binary the
    /// daemon would spawn" has to be exactly one file rather than a search.
    static func locateSiblingExecutable(
        of daemonExecutable: URL? = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    ) -> URL? {
        guard let daemonExecutable else { return nil }
        let candidate = daemonExecutable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("TBDModelProxy")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            // `.debug`, not `.error`, because the supervisor is constructed on
            // every boot regardless of the flag: an install with the proxy off
            // — the shipped default — would otherwise log a per-boot error
            // about a feature nobody asked for. The fact is not lost where it
            // matters. `daemon.capabilities` answers unsupported and Settings
            // greys the streaming toggle out with a caption, and a gated start
            // that finds no spawner says so at `.info` in `attemptSpawn`, which
            // is the one moment a missing binary changes what a user gets.
            Self.logger.debug(
                """
                no TBDModelProxy binary beside the running daemon at \
                \(candidate.path, privacy: .public); no session can be proxied
                """)
            return nil
        }
        return candidate
    }

    // MARK: - Spawn

    /// Starts a proxy for `home` on `port`, and returns once it has published
    /// the port it actually took.
    ///
    /// `port` may be 0, which asks the kernel for one; the returned port is
    /// always what the proxy wrote to its pid file, never what was requested,
    /// because those differ on the very first spawn of a home (spec, "Port").
    func spawn(port: Int, home: URL) async throws -> (pid: pid_t, port: Int) {
        let paths = ProxyHomePaths(home: home)

        do {
            try FileManager.default.createDirectory(
                at: paths.proxyDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            Self.logger.error(
                """
                could not create \(paths.proxyDir.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw Error.homeUnusable
        }

        let lock: HolderLock
        do {
            lock = try HolderLock.acquire(path: paths.lockPath)
        } catch HolderLock.Error.alreadyHeld {
            // Deliberately nothing else: no probe, no unlink, no stat. The
            // lock is the proof, and touching the rendezvous here is the exact
            // hazard it exists to prevent. The caller probes the port.
            throw Error.lockHeld
        } catch {
            Self.logger.error(
                """
                could not take \(paths.lockPath, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw Error.homeUnusable
        }
        var lockReleased = false
        defer { if !lockReleased { lock.release() } }

        let pid = try launch(port: port, home: home, paths: paths, lock: lock)

        // The proxy now owns the lock through its own copy of the open file
        // description. Dropping ours makes it the sole owner, which is what
        // makes the kernel release the lock exactly when it dies.
        lock.release()
        lockReleased = true

        return try await awaitPublishedPort(pid: pid, requestedPort: port, paths: paths)
    }

    // MARK: - Waiting for the port

    /// Polls the pid file until it names `pid` and a port, the child exits, or
    /// the budget runs out.
    ///
    /// **The pid must match.** A predecessor that is retiring leaves its own
    /// pid file in place until it exits (`ProxyPIDFile.removeIfOwned`), so a
    /// spawner that read the first pid file it saw would return a port a
    /// different process owns. Matching on the pid we were handed by
    /// `posix_spawn` makes the read unambiguous with no unlink and no window.
    ///
    /// Elapsed time is accumulated from the poll interval rather than measured
    /// against a deadline, for `HolderSpawner.awaitBinding`'s reason: `any
    /// Clock<Duration>` pins `Duration` but not `Instant`, so instant
    /// arithmetic does not typecheck through the existential.
    private func awaitPublishedPort(
        pid: pid_t, requestedPort: Int, paths: ProxyHomePaths
    ) async throws -> (pid: pid_t, port: Int) {
        var waited: Duration = .zero
        // Diagnostic only — nothing branches on either. `waited` is credit
        // spent at the nominal poll interval; these two say what that credit
        // bought in real time, which is the one thing a CI failure here cannot
        // be reasoned about without.
        var polls = 0
        let startedAt = Date()
        while true {
            // A cancelled spawn stops here rather than spinning through the
            // rest of its budget: `try? await clock.sleep` returns *instantly*
            // once the task is cancelled, so a loop that did not look would
            // burn every remaining iteration at full speed. The child is
            // killed on the way out for `bindTimeout`'s reason — nobody was
            // ever told its port, and it is holding `proxy.lock` — which keeps
            // this type's promise that a spawn it cannot finish leaves no
            // process and no lock behind.
            if Task.isCancelled {
                Self.killAndReap(pid: pid)
                Self.logger.error(
                    """
                    model proxy spawn for \(paths.home.path, privacy: .public) was cancelled; \
                    pid \(pid, privacy: .public) killed
                    """)
                throw CancellationError()
            }

            if let published = Self.publishedPort(path: paths.pidPath, pid: pid) {
                Self.logger.info(
                    """
                    model proxy pid \(pid, privacy: .public) bound port \
                    \(published, privacy: .public) for \(paths.home.path, privacy: .public)
                    """)
                return (pid, published)
            }

            // Read *after* the pid file, so a proxy that published a port and
            // then died in the same instant is still reported as a success —
            // the port is a fact, and whether the process is still alive is
            // the watch's question rather than the spawn's.
            if let status = Self.reapIfExited(pid: pid) {
                throw Self.classify(exitStatus: status, requestedPort: requestedPort)
            }

            guard waited < bindTimeout else { break }
            polls += 1
            try? await clock.sleep(for: bindPollInterval)
            waited += bindPollInterval
        }

        // No pid file and still running. The proxy writes that file *after* it
        // binds, so this is either a process that never bound or one that
        // bound and could not say so — and neither is reachable by any
        // session, because a session learns the port from this return value.
        // It is holding `proxy.lock`, so leaving it alive would block every
        // later spawn for this home forever, and it can orphan nothing: a
        // proxy has no children and no stream can exist on a port nobody was
        // ever told.
        Self.killAndReap(pid: pid)
        let elapsed = Date().timeIntervalSince(startedAt)
        Self.logger.error(
            """
            model proxy pid \(pid, privacy: .public) never published a port after \
            \(polls, privacy: .public) polls over \
            \(String(format: "%.1f", elapsed), privacy: .public)s of real time \
            (budget \("\(bindTimeout)", privacy: .public)); killed. See \
            \(paths.logPath, privacy: .public)
            """)
        throw Error.bindTimeout(polls: polls, elapsed: elapsed)
    }

    /// The port in a pid file that names `pid`, or nil for a missing file, an
    /// unreadable one, or one that names somebody else.
    ///
    /// The parse is `ModelProxyPIDFile`'s, so the spawner and the supervisor's
    /// adoption check read one spelling of the file rather than two.
    static func publishedPort(path: String, pid: pid_t) -> Int? {
        guard let record = ModelProxyPIDFile().read(path: path), record.pid == pid else {
            return nil
        }
        return record.port
    }

    /// The exit status of `pid` if it has exited, having reaped it; nil while
    /// it is still running or is not ours to collect.
    static func reapIfExited(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let collected = waitpid(pid, &status, WNOHANG)
        guard collected == pid else { return nil }
        return exitStatus(fromWaitpidStatus: status)
    }

    /// The number to classify on, out of a raw `waitpid` status.
    ///
    /// A child killed by a signal is reported as the **negated** signal
    /// number, so it can never collide with one of the proxy's own statuses:
    /// `SIGQUIT` is 3 and `bindFailed` is 3, and a crashed proxy answered as
    /// "could not bind" would send the supervisor probing a port nothing ever
    /// took.
    static func exitStatus(fromWaitpidStatus status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7f
        if terminatingSignal != 0 { return -terminatingSignal }
        return (status >> 8) & 0xff
    }

    /// Maps what the proxy exited with onto what the caller should do about it
    /// (`TBDModelProxyExit`, mirrored here because that enum lives in the
    /// proxy's executable target).
    static func classify(exitStatus: Int32, requestedPort: Int) -> Error {
        switch exitStatus {
        case 3: return .bindFailed(port: requestedPort)
        case 4: return .lockHeld
        case 5: return .homeUnusable
        default: return .childExited(status: exitStatus)
        }
    }

    /// SIGKILL and collect, so a failed spawn leaves no process and no lock.
    private static func killAndReap(pid: pid_t) {
        kill(pid, SIGKILL)
        var ignored: Int32 = 0
        _ = waitpid(pid, &ignored, 0)
    }

    // MARK: - posix_spawn

    /// The proxy's command line. `--lock-fd` is always passed: this spawner
    /// always takes the lock first, so the child must adopt it rather than
    /// race for one it cannot get.
    static func commandLine(executablePath: String, port: Int, home: URL) -> [String] {
        [
            executablePath,
            "--port", String(port),
            "--home", home.path,
            "--lock-fd", String(lockDescriptorNumber),
        ]
    }

    private func launch(port: Int, home: URL, paths: ProxyHomePaths, lock: HolderLock) throws
        -> pid_t
    {
        // `</dev/null` and a real file for stdout and stderr, never inherited
        // descriptors: a proxy that inherited the daemon's stdout would hold
        // that pipe open for its whole life, so whatever reads it never sees
        // EOF. The proxy writes nothing to stdout by contract, which makes
        // anything in `proxy.log` a diagnostic.
        let nullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        let nullErrno = errno
        let logFD = open(paths.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        let logErrno = errno
        defer {
            if nullFD >= 0 { close(nullFD) }
            if logFD >= 0 { close(logFD) }
        }
        // Each errno is captured beside its own call: a guard that read
        // `errno` after both opens would report whichever syscall touched it
        // last, which on a failed first open is a *successful* second one.
        guard nullFD >= 0 else { throw Error.launchFailed(errno: nullErrno) }
        guard logFD >= 0 else { throw Error.launchFailed(errno: logErrno) }

        // Relocated above the target rather than passed where it sits: see
        // `descriptorRelocationFloor`. `F_DUPFD_CLOEXEC` keeps the duplicate
        // close-on-exec in *this* process, so clearing the flag never exposes
        // the lock to another concurrent `posix_spawn` in the daemon.
        let lockSource = fcntl(
            lock.fileDescriptor, F_DUPFD_CLOEXEC, Self.descriptorRelocationFloor)
        guard lockSource >= 0 else {
            let saved = errno
            throw Error.launchFailed(errno: saved)
        }
        defer { close(lockSource) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // In order, and the stdio dup2s first: if `/dev/null` or the log
        // happened to land on the lock's target number it has already been
        // copied to its final home by the time it is overwritten. The lock's
        // source cannot be a target — it was relocated above the floor — and
        // there are deliberately no trailing closes, which would destroy the
        // descriptor the dup2 just placed.
        posix_spawn_file_actions_adddup2(&actions, nullFD, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        posix_spawn_file_actions_adddup2(&actions, lockSource, Self.lockDescriptorNumber)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // A signal mask is inherited and survives `execve`. This runs on a
        // Swift-concurrency worker thread, which blocks nearly everything, and
        // a proxy that inherited that mask could not be SIGTERMed — which is
        // how the supervisor asks one to go away when the control endpoint is
        // not answering. `SETSIGDEF` for the dispositions, for the same
        // reason: `SIG_IGN` survives exec too, and the proxy installs the two
        // it wants (`SIGHUP`, `SIGPIPE`) itself.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var argv = Self.commandLine(
            executablePath: executableURL.path, port: port, home: home
        ).map { strdup($0) }
        argv.append(nil)
        // Sorted so a proxy's environment is reproducible in a log or a crash
        // report; the child cannot observe the order.
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
            throw Error.launchFailed(errno: status)
        }
        return pid
    }
}

/// The four paths a proxy's home holds, all derived from `TBDConstants` so
/// `TBD_HOME` — and with it the test fence — moves them together. Nothing here
/// is composed from `$HOME` or from a string literal join.
struct ProxyHomePaths: Sendable {
    let home: URL
    let proxyDir: URL
    let lockPath: String
    let pidPath: String
    let logPath: String

    init(home: URL) {
        let environment = ["TBD_HOME": home.path]
        self.home = home
        self.proxyDir = TBDConstants.modelProxyDir(environment: environment)
        self.lockPath = TBDConstants.modelProxyLockPath(environment: environment)
        self.pidPath = TBDConstants.modelProxyPIDPath(environment: environment)
        self.logPath = TBDConstants.modelProxyLogPath(environment: environment)
    }
}
