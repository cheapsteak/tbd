import Darwin
import Foundation
import TBDShared
import os

// Everything TBDModelProxy decides, so it can be exercised without spawning a
// process — `main.swift` next door holds nothing but the call into `run()`.
// The split mirrors `TBDHolder`/`Holder.swift`, for the same reason: a
// five-branch argument parser and an exit-code taxonomy are worth testing
// directly, and a top-level `main.swift` offers a test nothing but a binary.
//
// TBDModelProxy — one process per TBD home
// (docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md).
//
// Invoked as:
//
//   TBDModelProxy [--port <n>] [--home <path>] [--lock-fd <n>]
//
// It listens on loopback, forwards every request under its base URL to the
// upstream a route names, and tees assistant text deltas into a per-terminal
// stream file. It is spawned by the daemon, outlives it, and is replaced only
// by a successor that takes `proxy.lock` first.
//
// Nothing is written to stdout, ever. A proxy's stdout and stderr are
// redirected into `proxy.log` by its spawner, so ordinary operation must leave
// that file empty; diagnostics go to `os.Logger` and only an invocation that
// cannot run at all reaches stderr. `no_print_in_sources` covers this target.

/// Exit statuses `TBDModelProxy` can end on, split the way `HolderExitCode`
/// splits the holder's: 2 means the command line is wrong and will stay wrong,
/// 3 means the machine refused and a later attempt can succeed.
enum TBDModelProxyExit {
    /// A missing or malformed flag. The same command line fails the same way
    /// forever, so a supervisor must fix its arguments rather than respawn.
    static let badArguments: Int32 = 2
    /// The listener could not bind the port it was asked for. Distinct from
    /// every other failure because it is the one the supervisor acts on: it
    /// probes `GET /tbd/status` on that port, adopts a TBD proxy that answers,
    /// and mints a fresh port when anything else holds it.
    static let bindFailed: Int32 = 3
    /// Another live proxy already holds `proxy.lock` for this home. Its own
    /// code rather than a bind failure, because the two call for opposite
    /// responses: a bind failure is a port to probe and possibly re-mint,
    /// while this says a proxy for this home is already running and the right
    /// move is to leave it alone. Only reachable when no `--lock-fd` was
    /// inherited — a spawner that took the lock itself has already learned
    /// this before it spawned anything.
    static let lockHeld: Int32 = 4
    /// The home the proxy was pointed at could not be made usable — its
    /// `proxy/`, `proxy/routes/` or `streams/` directory could not be created,
    /// or its lock file could not be opened for a reason other than
    /// contention. Retrying the same command line will fail the same way until
    /// somebody fixes the filesystem, so it is deliberately not `bindFailed`.
    static let homeUnusable: Int32 = 5
}

/// What the daemon puts on the proxy's command line.
///
/// Unrecognised `--flags` are refused rather than ignored — unlike the holder,
/// which must tolerate a newer daemon's flags because a session keeps the
/// holder binary it was born with. A proxy is replaced whenever its version
/// differs from the daemon's, so a flag it has never heard of is a bug, not
/// version skew.
struct ProxyArguments: Equatable {
    /// The port to bind. Zero asks the kernel to assign one, which is how the
    /// first proxy on a TBD home is started; every later one is asked for the
    /// port persisted in the config row.
    var port: Int
    /// The TBD home whose `proxy/`, `streams/` and route files this proxy owns.
    var home: String
    /// An inherited `flock` descriptor, already held by the spawner. That a
    /// descriptor cannot be inherited by accident is what makes it proof of
    /// ownership. The proxy holds it from start-up until its listener closes —
    /// a `POST /tbd/retire` — or until the process exits, whichever comes
    /// first; see `ProxyRendezvousLock`.
    var lockDescriptor: Int32?

    static let usage = "usage: TBDModelProxy [--port <n>] [--home <path>] [--lock-fd <n>]"

    /// `arguments` excludes argv[0].
    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProxyArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw ProxyStartupError.unknownArgument(flag)
            }
            let name = String(flag.dropFirst(2))
            guard ["port", "home", "lock-fd"].contains(name) else {
                throw ProxyStartupError.unknownArgument(flag)
            }
            guard index + 1 < arguments.count else {
                throw ProxyStartupError.missingValue(flag)
            }
            values[name] = arguments[index + 1]
            index += 2
        }

        var port = 0
        if let text = values["port"] {
            guard let parsed = Int(text), (0...65535).contains(parsed) else {
                throw ProxyStartupError.invalidPort(text)
            }
            port = parsed
        }

        var lockDescriptor: Int32?
        if let text = values["lock-fd"] {
            guard let parsed = Int32(text), parsed >= 0 else {
                throw ProxyStartupError.invalidLockDescriptor(text)
            }
            lockDescriptor = parsed
        }

        let home = values["home"].flatMap { $0.isEmpty ? nil : $0 }
            ?? TBDConstants.configDir(environment: environment).path

        return ProxyArguments(port: port, home: home, lockDescriptor: lockDescriptor)
    }
}

enum ProxyStartupError: LocalizedError, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidPort(String)
    case invalidLockDescriptor(String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let flag):
            return "unknown argument \(flag)\n\(ProxyArguments.usage)"
        case .missingValue(let flag):
            return "\(flag) needs a value\n\(ProxyArguments.usage)"
        case .invalidPort(let text):
            return "--port must be 0-65535, got \(text)"
        case .invalidLockDescriptor(let text):
            return "--lock-fd must be a non-negative descriptor, got \(text)"
        }
    }
}

/// Loggers live on a type rather than at top level: a top-level `let` in
/// `main.swift` is a main-actor-isolated global under the Swift 6 language
/// mode, which a signal handler cannot touch.
enum ProxyLog {
    static let main = Logger(subsystem: "com.tbd.modelproxy", category: "main")
}

enum TBDModelProxyMain {
    static func run() -> Never {
        let arguments: ProxyArguments
        do {
            arguments = try ProxyArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("TBDModelProxy: \(error.localizedDescription)\n".utf8))
            exit(TBDModelProxyExit.badArguments)
        }

        ProxyLog.main.debug(
            """
            starting: pid \(getpid(), privacy: .public), \
            port \(arguments.port, privacy: .public), \
            home \(arguments.home, privacy: .public), \
            lock-fd \(arguments.lockDescriptor.map(String.init) ?? "none", privacy: .public)
            """)

        // 1. Session first, disposition second — the holder's order, for the
        //    holder's reasons (`Sources/TBDHolder/Holder.swift`). `setsid`
        //    puts this process in a session of its own, so a Ctrl-C aimed at
        //    whatever spawned it cannot reach it and it orphans to launchd
        //    rather than dying with its spawner. `SIGHUP` ignored covers the
        //    controlling terminal going away; `SIGPIPE` ignored turns a write
        //    to a closed connection into an `EPIPE` the forwarder handles
        //    instead of a signal that kills a proxy serving other sessions.
        //
        //    EPERM here means we are already a process-group leader — a proxy
        //    started from a shell for diagnosis — which is not a reason to
        //    refuse to run.
        if setsid() == -1 {
            ProxyLog.main.debug(
                "setsid failed (errno \(errno, privacy: .public)); already a session leader")
        }
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        // 2. Termination is armed before anything that can block, so a SIGTERM
        //    arriving during start-up is honoured rather than killing the
        //    process by default action. `DispatchSource` rather than
        //    `signal(2)`: the handler then runs on a queue instead of in
        //    signal context and may do real work. The disposition must be
        //    ignored first, or the default action wins the race.
        //
        //    What a signal *means* is decided by `ProxySignalDisposition`:
        //    once the listener is up, the first one retires this proxy exactly
        //    as `POST /tbd/retire` does, and only the second exits without
        //    waiting for the drain. Until then — and this is the window this
        //    early arming exists for — there is nothing to drain, so a signal
        //    ends the process at once.
        let stopped = ProxyStopSignal()
        let signals = ProxySignalDisposition()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                switch signals.received() {
                case .retire(let retire):
                    ProxyLog.main.debug(
                        "received signal \(number, privacy: .public), retiring")
                    retire()
                case .exitNow:
                    ProxyLog.main.debug("received signal \(number, privacy: .public), stopping")
                    stopped.stop(reason: "signal \(number)")
                }
            }
            source.resume()
            return source
        }

        // Every path this process owns hangs off the home it was given, so the
        // one `TBD_HOME` override inside `ProxyPaths` is all it takes to give a
        // test — or a second checkout — its own proxy with no injection seam
        // added for the purpose.
        let paths = ProxyPaths(home: arguments.home)
        // Resolved once, here, and not per request: the daemon compares this
        // against its own home to tell its proxy from one serving a different
        // TBD home that the kernel happened to hand the same ephemeral port.
        // Both sides canonicalize through the same function, because
        // `~/tbd`, `/tmp/x/../x/tbd` and a path through a symlinked `/var` are
        // one directory and have to compare equal.
        let servedHome = ModelProxyStatus.canonicalHome(arguments.home)
        do {
            try paths.create()
        } catch {
            let diagnostic =
                "TBDModelProxy: could not prepare \(arguments.home): "
                + "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            exit(TBDModelProxyExit.homeUnusable)
        }

        // 3. The lock, before any bind, is what makes "a proxy for this home is
        //    already running" answerable without connecting to it.
        //
        //    Two ways to hold it, one meaning. A `--lock-fd` was taken by the
        //    spawner and rode in on a `dup2` file action, which is proof of
        //    ownership precisely because a descriptor cannot be inherited by
        //    accident. Without one — a test, a proxy started by hand — this
        //    process takes the lock itself. A second proxy on one home fails
        //    here either way.
        //
        //    Held from here until the listener closes, and not until exit:
        //    what the lock means is "a live proxy owns this rendezvous", and a
        //    retired proxy with a closed listener owns no port and answers no
        //    route. See `ProxyRendezvousLock`.
        let rendezvous: ProxyRendezvousLock
        if let inherited = arguments.lockDescriptor {
            ProxyLog.main.debug(
                "holding the inherited lock descriptor \(inherited, privacy: .public)")
            rendezvous = ProxyRendezvousLock(inherited: inherited)
        } else {
            do {
                let own = try HolderLock.acquire(path: paths.lockPath)
                rendezvous = ProxyRendezvousLock(acquired: own)
            } catch HolderLock.Error.alreadyHeld(let path) {
                FileHandle.standardError.write(
                    Data("TBDModelProxy: another proxy already holds \(path)\n".utf8))
                exit(TBDModelProxyExit.lockHeld)
            } catch {
                FileHandle.standardError.write(
                    Data("TBDModelProxy: \(error.localizedDescription)\n".utf8))
                exit(TBDModelProxyExit.homeUnusable)
            }
        }
        // Read once, and named, so the lock is visibly still owned past the
        // branch that took it. `HolderLock` is a `deinit`-free struct, so
        // nothing here is keeping the descriptor alive: it stays open — and
        // the lock with it — until `releaseRendezvousLock()` closes it.
        let heldDescriptor: Int32 = rendezvous.fileDescriptor
        ProxyLog.main.debug("lock held on descriptor \(heldDescriptor, privacy: .public)")

        let routes = RouteTable(routesDir: paths.routesDir, streamsDir: paths.streamsDir)
        let tee = StreamTee(streamsDir: paths.streamsDir)

        // The port the kernel actually assigned, which `--port 0` does not
        // know until the bind below returns. Status must report the port a
        // successor would have to take, not the one this process asked for.
        let boundPort = ProxyPortBox(requested: arguments.port)
        // Read once from the kernel rather than composed from "now": the
        // daemon adopts a proxy by matching this against the process table, so
        // a value invented here is one that can only ever fail to match.
        // `nil` is a kernel that refused to describe this process, which is
        // not a reason to refuse to start; the adoption probe simply will not
        // match, and the daemon mints a fresh port.
        let processStart = ProcessStartTime.startTime(pid: getpid()) ?? Date()

        let server = ProxyServer(
            port: arguments.port,
            routes: routes,
            tee: tee,
            // Identity and port only: the control endpoint fills in
            // `streamsInFlight` and `routeCount` from live state at the moment
            // of the request, because this closure is synchronous and cannot
            // await the route table's actor.
            status: {
                ModelProxyStatus(
                    version: TBDModelProxyVersion.current, pid: getpid(),
                    processStartTime: processStart, port: boundPort.value,
                    streamsInFlight: 0, routeCount: 0, home: servedHome)
            },
            // Reached only after a retire — a `POST /tbd/retire` or a signal —
            // has closed the listener and drained the streams that were still
            // running on it. It joins the one shutdown path rather than calling
            // `exit` itself, so the pid file is reclaimed the same way on every
            // route out of this process.
            onRetire: { stopped.stop(reason: "retire") },
            // Fired the moment the listener is gone and before the retire's
            // 200 is written, so the successor's spawner can take the lock as
            // soon as it has its answer rather than waiting out this process's
            // drain. Also fired by `stop()`, where it is a no-op ahead of an
            // exit that would have closed the descriptor anyway.
            onListenerClosed: { rendezvous.releaseRendezvousLock() })

        // `run()` is synchronous and returns `Never`, so the async start is
        // driven to completion here rather than escaping into a task nobody
        // waits on: a bind failure has to become an exit status before the
        // signal wait below begins.
        let startOutcome = BlockingResultBox<Int>()
        Task {
            do {
                // A directory that cannot be listed is worth a line and not
                // worth refusing to start over: the daemon rewrites route
                // files as it spawns, so an empty table recovers by itself.
                try await routes.loadAll()
            } catch {
                ProxyLog.main.error(
                    "route load failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                startOutcome.finish(.success(try await server.start()))
            } catch {
                startOutcome.finish(.failure(error))
            }
        }

        switch startOutcome.wait() {
        case .success(let port):
            boundPort.value = port
            ProxyLog.main.debug("bound port \(port, privacy: .public)")
        case .failure(let error):
            // Deliberately no pid file on this path: a reader who finds one is
            // entitled to assume the port in it is bound.
            FileHandle.standardError.write(
                Data("TBDModelProxy: bind failed: \(error.localizedDescription)\n".utf8))
            exit(TBDModelProxyExit.bindFailed)
        }

        // 4. The pid file, after the bind, so the port in it is a port that is
        //    actually listening. A failure here is logged and survived: the
        //    proxy is already serving, and the daemon finds it by the port in
        //    its config row rather than by this file.
        let pid = getpid()
        do {
            try ProxyPIDFile.write(path: paths.pidPath, pid: pid, port: boundPort.value)
        } catch {
            ProxyLog.main.error(
                """
                could not write \(paths.pidPath, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }

        // 5. The signal path joins the retire path, now that there is a
        //    listener to close and a drain to run.
        //
        //    A SIGTERM is how a supervisor, a process manager, or a person at
        //    a shell stops a proxy, and a proxy that answered it by tearing
        //    down its event loops would cut every turn it was carrying — the
        //    transcript corruption this whole feature exists to avoid, arriving
        //    by the most ordinary gesture there is. So the first signal runs
        //    the same retire the control endpoint runs: close the listener,
        //    release the rendezvous lock, drain under the same cap, exit the
        //    same way. `retireNow` is idempotent, so a signal landing during an
        //    HTTP retire's drain joins that drain rather than disturbing it.
        signals.armRetire {
            Task { await server.retireNow() }
        }

        // 6. The retention watch. It samples on the clock and joins the same
        //    shutdown path as a signal, so a self-retiring proxy reclaims its
        //    pid file exactly as a TERMed one does.
        let retireWatch = ProxyRetireWatch(
            lastDaemonContact: { server.lastDaemonContact },
            streamsInFlight: { server.streamsInFlight },
            onRetire: { stopped.stop(reason: "unattended for 24h with no stream in flight") })
        let watchTask = Task { await retireWatch.run() }

        let reason = stopped.wait()
        watchTask.cancel()
        // Keeps the sources alive until the wait returns; a cancelled source
        // stops delivering, and a released one is cancelled.
        for source in sources { source.cancel() }

        let stopOutcome = BlockingResultBox<Void>()
        Task {
            await server.stop()
            stopOutcome.finish(.success(()))
        }
        _ = stopOutcome.wait()

        // Idempotent, and belt-and-braces: `stop()` closes the listener, which
        // fires the same release. Stated here as well because the invariant
        // this process owes its successor — the lock is never held past the
        // listener — must not depend on the shape of `stop()`.
        rendezvous.releaseRendezvousLock()

        // Only while it is still ours. A retiring proxy exits *after* its
        // successor has bound the port and written its own pid file, and an
        // unconditional unlink here would leave that live successor with no
        // rendezvous.
        let removed = ProxyPIDFile.removeIfOwned(path: paths.pidPath, pid: pid)
        ProxyLog.main.debug(
            """
            exiting (\(reason, privacy: .public)); \
            pid file \(removed ? "removed" : "left in place", privacy: .public)
            """)
        exit(0)
    }
}

/// The one way out of `run()`: whichever of a finished drain — a `POST
/// /tbd/retire`'s, a signal's, or the retention watch's — a signal arriving
/// before there is a listener to close, or a second signal during a drain gets
/// there first wakes the main thread and says why.
///
/// A semaphore plus a one-shot reason rather than a bare `DispatchSemaphore`,
/// because several unrelated paths reach it and the log line that follows is
/// the only place a reader learns which one did. Extra `stop` calls are counted
/// by the semaphore and ignored by the reason, which is what makes it safe for
/// a drain to finish just as a second signal lands.
final class ProxyStopSignal: Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private nonisolated(unsafe) var reason: String?

    func stop(reason: String) {
        lock.withLock {
            guard self.reason == nil else { return }
            self.reason = reason
        }
        ready.signal()
    }

    /// Blocks until the first `stop` and returns its reason.
    func wait() -> String {
        ready.wait()
        return lock.withLock { reason } ?? "unknown"
    }
}

/// What a SIGTERM or SIGINT means, which depends on what has already arrived.
///
/// **The first signal a serving proxy gets means what `POST /tbd/retire`
/// means**: close the listener, release the rendezvous lock, let the turns
/// already in flight finish under the drain cap, and exit when the drain ends.
/// A signal is how a process manager, a supervisor, or a person at a shell
/// stops a proxy, and answering it by tearing the event loops down would
/// truncate every stream the proxy was carrying — the transcript corruption
/// this feature exists to avoid, reached by the most ordinary gesture there is.
///
/// **The second one exits immediately**, cutting whatever is still open. It is
/// the operator saying they meant now, and it exists so that "stop this proxy
/// this instant" is a second signal away rather than a `SIGKILL` away.
///
/// **Before the retire disposition is armed there is nothing to drain**, so a
/// signal exits at once. `armRetire` is what turns the first signal into a
/// retire, and it is called only after the bind succeeds and the pid file is
/// written — so the unarmed window spans that startup sequence, not merely the
/// time before the listener is bound — which is also why the count alone
/// cannot decide: a proxy caught in that window would otherwise sit in a
/// retire that was never armed.
final class ProxySignalDisposition: @unchecked Sendable {
    /// What the handler should do about the signal it just took.
    enum Disposition {
        /// Run the retire the control endpoint would have run.
        case retire(@Sendable () -> Void)
        /// Wake the main thread and end the process.
        case exitNow
    }

    private let lock = NSLock()
    private var retire: (@Sendable () -> Void)?
    private var count = 0

    /// Arms the retire path. Called exactly once, after the bind succeeds and
    /// the pid file is written — a second call is a bug (asserted in debug)
    /// and is ignored rather than replacing the already-armed closure.
    func armRetire(_ retire: @escaping @Sendable () -> Void) {
        lock.withLock {
            assert(self.retire == nil, "armRetire called more than once")
            guard self.retire == nil else { return }
            self.retire = retire
        }
    }

    /// Counts one signal and says what to do about it.
    func received() -> Disposition {
        lock.withLock { () -> Disposition in
            count += 1
            guard count == 1, let armed = self.retire else { return .exitNow }
            return .retire(armed)
        }
    }

    /// How many signals have been taken, for a test and for a log line.
    var signalCount: Int { lock.withLock { count } }
}

/// The `flock` that says a live proxy owns this home's rendezvous.
///
/// Two ways in, one way out. A `--lock-fd` inherited through a `dup2` file
/// action is the spawner's own descriptor, and the daemon drops its copy right
/// after `posix_spawn` (`HolderSpawner`); a proxy started with no descriptor
/// takes the lock itself. Either way the lock lives on an open file
/// description, so closing the descriptor is what releases it.
///
/// **Held from start-up until the listener closes, or until the process exits,
/// whichever comes first.** Not until exit, which is the tempting rule and the
/// wrong one: `POST /tbd/retire` closes the listener, answers immediately, and
/// only then drains streams that may run for minutes. What the lock means is
/// "a live proxy owns this rendezvous", and a proxy whose listener is closed
/// owns no port and answers no route — so holding it through the drain would
/// block the successor's spawner for the length of the drain, leaving nothing
/// listening on the port. The pid file needs no such rule: it is reclaimed
/// only while it still names this process.
///
/// `@unchecked Sendable` with an `NSLock`: the release is reachable from the
/// event loop that answers a retire and from the main thread on the way out,
/// and it must happen exactly once.
final class ProxyRendezvousLock: @unchecked Sendable {
    private let lock = NSLock()
    private var acquired: HolderLock?
    private var inherited: Int32?

    /// A lock this process took for itself.
    init(acquired: HolderLock) { self.acquired = acquired }

    /// A lock the spawner took and handed down on a descriptor.
    init(inherited: Int32) { self.inherited = inherited }

    /// The descriptor the lock lives on, or -1 once it has been released.
    var fileDescriptor: Int32 {
        lock.withLock { acquired?.fileDescriptor ?? inherited ?? -1 }
    }

    /// Drops the lock, so a successor's spawner can take it.
    ///
    /// Idempotent, and it must be: the retire path releases at listener close
    /// and the exit path releases again, and closing a descriptor twice is not
    /// a harmless mistake — the number can have been handed to something else
    /// in between.
    func releaseRendezvousLock() {
        enum Held {
            case own(HolderLock)
            case handedDown(Int32)
        }
        let held = lock.withLock { () -> Held? in
            defer {
                self.acquired = nil
                self.inherited = nil
            }
            if let own = self.acquired { return .own(own) }
            if let handedDown = self.inherited { return .handedDown(handedDown) }
            return nil
        }
        switch held {
        case .own(let own):
            own.release()
        case .handedDown(let descriptor):
            close(descriptor)
        case .none:
            return
        }
        ProxyLog.main.debug("released the rendezvous lock")
    }
}

/// The proxy's build identity, as `GET /tbd/status` reports it.
///
/// The daemon compares this against the identity it computes for the sibling
/// `TBDModelProxy` binary it would spawn, and retires a proxy whose version
/// *differs* (spec, "Supervisor"). The formula lives in `TBDShared` so both
/// sides compute the same string — see `ModelProxyVersion`.
///
/// Computed once, at first use, from the executable this process is running.
/// Once rather than per request because the file cannot change identity under
/// a running image in any way this process could act on: a rebuild replaces
/// the file, and the process keeps the inode it was exec'd from.
enum TBDModelProxyVersion {
    static let current: String = ModelProxyVersion.currentExecutable()
}

// MARK: - The home's directories

/// Every path a proxy owns, derived from the home it was given.
///
/// The single `TBD_HOME` override is the whole seam: `TBDConstants` composes
/// all of these from it, so a test — or a second checkout — gets its own proxy
/// with nothing injected for the purpose, and no path here is hand-built from
/// `$HOME`.
struct ProxyPaths: Sendable {
    let proxyDir: URL
    let routesDir: URL
    let streamsDir: URL
    let lockPath: String
    let pidPath: String

    init(home: String) {
        let environment = ["TBD_HOME": home]
        proxyDir = TBDConstants.modelProxyDir(environment: environment)
        routesDir = TBDConstants.modelProxyRoutesDir(environment: environment)
        streamsDir = TBDConstants.streamsDir(environment: environment)
        lockPath = TBDConstants.modelProxyLockPath(environment: environment)
        pidPath = TBDConstants.modelProxyPIDPath(environment: environment)
    }

    /// Creates the three directories at mode 0700, before anything binds.
    ///
    /// 0700 and not the umask's answer: `routes/` holds forwarding tokens and
    /// `streams/` holds the assistant's own words, and both sit in a home the
    /// user owns on a machine other accounts may share. The mode is also
    /// *re-applied* to a directory that already existed, so a home created by
    /// an older image — or by a umask that let group bits through — is
    /// tightened rather than trusted.
    func create(fileManager: FileManager = .default) throws {
        for directory in [proxyDir, routesDir, streamsDir] {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Best effort: a directory somebody else owns cannot be chmod'ed,
            // and refusing to start over a mode is worse than starting.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

// MARK: - The pid file

/// `<home>/proxy/proxy.pid`: `<pid>\n<port>\n`, written after the bind.
///
/// After, so that a reader who sees the file can trust the port — the whole
/// point of the file for a human debugging a home, since the daemon reads the
/// port out of its config row rather than from here.
enum ProxyPIDFile {
    static func contents(pid: Int32, port: Int) -> String {
        "\(pid)\n\(port)\n"
    }

    /// Written temp-and-rename (`Data`'s `.atomic`), so a reader never sees a
    /// half-written file and a crash mid-write leaves the previous one intact.
    static func write(path: String, pid: Int32, port: Int) throws {
        try Data(contents(pid: pid, port: port).utf8)
            .write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    /// The pid a pid file's first line names, or nil for anything else.
    static func pid(inContentsOf path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            let first = text.split(separator: "\n").first
        else {
            return nil
        }
        return Int32(first.trimmingCharacters(in: .whitespaces))
    }

    /// Unlinks the pid file, but only while it still names `pid`.
    ///
    /// Load-bearing on the retire path and not defensive tidiness: a retiring
    /// proxy answers, drains, and exits *after* its successor has already
    /// bound the port and written its own pid file. An unconditional unlink on
    /// the way out would delete the successor's file and leave a live proxy
    /// with no rendezvous.
    @discardableResult
    static func removeIfOwned(path: String, pid: Int32) -> Bool {
        guard self.pid(inContentsOf: path) == pid else { return false }
        return unlink(path) == 0
    }
}

// MARK: - Retention

/// Retires a proxy nobody is supervising (spec, "Retention").
///
/// A proxy outlives the daemon that spawned it deliberately — that is the
/// point of a separate process — so nothing else would ever reclaim one whose
/// TBD install was deleted, whose home was abandoned, or whose daemon simply
/// never came back. The watch samples two facts on a timer and retires only
/// when both hold: no daemon has driven a `/tbd/…` verb inside the window, and
/// no stream is in flight. The second is what keeps a long turn from being cut
/// by a timer.
///
/// **Why the interval is a `Clock` and the window is a `Date` span.** The
/// repo's split: `Duration` is behavior, `Date` is data. The 60-second pacing
/// is this loop's own behavior and rides the injected clock, so a test crosses
/// it in a couple of advances. The 24 hours is a span between two wall-clock
/// moments — one of them stamped by an inbound request — and comparing it on a
/// monotonic clock would answer the wrong question after a laptop sleeps.
struct ProxyRetireWatch: Sendable {
    static let log = Logger(subsystem: "com.tbd.modelproxy", category: "retention")

    /// Production pacing. Sixty seconds against a 24-hour window is 1440
    /// samples over the window — the cost of a wake-up per minute buys a
    /// bounded overshoot rather than precision anybody needs.
    static let defaultCheckInterval: Duration = .seconds(60)
    static let defaultUnattendedAfter: TimeInterval = 24 * 60 * 60

    private let lastDaemonContact: @Sendable () -> Date
    private let streamsInFlight: @Sendable () -> Int
    private let onRetire: @Sendable () -> Void
    private let checkInterval: Duration
    private let unattendedAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    init(
        lastDaemonContact: @escaping @Sendable () -> Date,
        streamsInFlight: @escaping @Sendable () -> Int,
        onRetire: @escaping @Sendable () -> Void,
        checkInterval: Duration = ProxyRetireWatch.defaultCheckInterval,
        unattendedAfter: TimeInterval = ProxyRetireWatch.defaultUnattendedAfter,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.lastDaemonContact = lastDaemonContact
        self.streamsInFlight = streamsInFlight
        self.onRetire = onRetire
        self.checkInterval = checkInterval
        self.unattendedAfter = unattendedAfter
        self.now = now
        self.clock = clock
    }

    /// One sample, without the loop around it.
    func isUnattendedAndIdle(at moment: Date) -> Bool {
        guard streamsInFlight() == 0 else { return false }
        return moment.timeIntervalSince(lastDaemonContact()) >= unattendedAfter
    }

    /// Samples until one comes back true, then hands over to `onRetire` once
    /// and returns. Sleeps first, so a proxy cannot retire before it has
    /// served anything.
    func run() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: checkInterval)
            } catch {
                return
            }
            let moment = now()
            guard isUnattendedAndIdle(at: moment) else { continue }
            let unattendedFor = Int(moment.timeIntervalSince(lastDaemonContact()))
            Self.log.info(
                """
                retiring: no daemon has driven a control endpoint for \
                \(unattendedFor, privacy: .public)s and no stream is in flight
                """)
            onRetire()
            return
        }
    }
}

/// The port the listener actually bound.
///
/// `--port 0` is the first proxy on a TBD home, and the number that matters —
/// the one the daemon persists and every later proxy is asked for — exists
/// only after the bind. The box is written once, from `run()`, and read from
/// the status closure on whatever thread a control request arrives on.
final class ProxyPortBox: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var port: Int

    init(requested: Int) { self.port = requested }

    var value: Int {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }
}

/// A one-shot result handed from a `Task` back to the synchronous `run()`.
///
/// `run()` returns `Never` and owns the process, so it cannot become `async`
/// without moving the exit-code taxonomy somewhere a test cannot reach. This
/// box is the narrow bridge: one `finish`, one `wait`, no polling.
final class BlockingResultBox<Value: Sendable>: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) {
        let first = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            result = value
            return true
        }
        guard first else { return }
        ready.signal()
    }

    func wait() -> Result<Value, Error> {
        ready.wait()
        // Non-nil by construction: the semaphore is signalled only after the
        // result is stored, and `finish` stores exactly once.
        return lock.withLock { result } ?? .failure(ProxyServerError.boundAddressUnreadable)
    }
}
