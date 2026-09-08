import Darwin
import Foundation
import TBDShared
import os

/// What the supervisor needs out of a spawner, as a protocol so a test can
/// answer with the four `ModelProxySpawner.Error`s a real spawn only produces
/// by racing something (a port squatter held for the length of a spawn, a
/// filesystem that refuses a directory, a lock another daemon holds).
///
/// Both requirements are `async` so an actor can witness them; the real
/// spawner's `reapIfExited` is a synchronous `waitpid`.
protocol ModelProxySpawning: Sendable {
    func spawn(port: Int, home: URL) async throws -> (pid: pid_t, port: Int)
    /// The exit status of a proxy **this process spawned**, having reaped it;
    /// nil while it is still running or is not ours to collect.
    func reapIfExited(pid: pid_t) async -> Int32?
}

extension ModelProxySpawner: ModelProxySpawning {
    func reapIfExited(pid: pid_t) -> Int32? { Self.reapIfExited(pid: pid) }
}

/// Whether a pid still names the process a `/tbd/status` answer described.
///
/// A pid on its own is not an identity — the kernel reissues numbers — and a
/// proxy is adopted, signalled by nobody, and trusted with every session's
/// traffic, so the check has to be the same one `AgentReaper` makes before it
/// signals anything (spec, "Rendezvous and identity").
protocol ProcessIdentityChecking: Sendable {
    func matches(pid: Int32, startTime: Date) -> Bool
}

/// The production check, over the real process table.
struct ProcessTableIdentityCheck: ProcessIdentityChecking {
    /// How far the observed start time may sit from the one the proxy
    /// reported.
    ///
    /// **One second, and it is not slack.** The proxy reads its own start time
    /// out of `kinfo_proc` and reports microseconds
    /// (`ProcessStartTime.startTime`); `ProcessSignaller.startTime` reads the
    /// same instant back through `ps -o lstart=`, which prints whole seconds.
    /// The two therefore differ by the truncated fraction — strictly less than
    /// one second — and zero tolerance would reject every live proxy started
    /// at anything but a whole second. The executable gate behind it is what
    /// narrows a pid that happens to have started inside the same second.
    static let startTimeTolerance: TimeInterval = 1

    let signaller: any ProcessSignaller

    init(signaller: any ProcessSignaller = ProductionProcessSignaller()) {
        self.signaller = signaller
    }

    func matches(pid: Int32, startTime: Date) -> Bool {
        ProcessIdentityCheck.verify(
            pid: pid,
            startedWithin: Self.startTimeTolerance,
            of: startTime,
            executableIsAcceptable: { $0.contains("TBDModelProxy") },
            signaller: signaller
        ) == .same
    }
}

/// Owns the model proxy's life for one TBD home: adopt or spawn at startup,
/// watch it, replace it when it dies or when its build differs from this
/// daemon's, and make and retire the routes sessions are spawned against
/// (spec, "The daemon" → "Supervisor").
///
/// **This is the proxy process's named reconciler.** `ModelProxySpawner`
/// guarantees only that a spawn it cannot finish leaves nothing behind; a
/// *successful* spawn produces a process that deliberately outlives the daemon
/// (`setsid`, orphans to launchd), and everything that happens to it
/// afterwards is decided here. The rendezvous files a SIGKILLed proxy could
/// not unlink, and route and stream files whose terminal is gone, are the
/// `OrphanGC` leg's — this type owns the process and the routes it is asked
/// to make.
///
/// ## Three rules that are easy to state backwards
///
/// - **A held lock means probe, not replace.** `.lockHeld` says a live proxy
///   owns this rendezvous. The supervisor probes `/tbd/status` on the
///   persisted port and adopts what answers; when nothing does it logs loudly
///   and stays empty. It never unlinks the lock — that is the one action that
///   could put two proxies on one home.
/// - **A free lock is not proof the predecessor is gone.** `POST /tbd/retire`
///   answers as soon as the listener is closed and the lock released, and the
///   old process keeps draining for up to ten minutes. The successor is
///   spawned the moment the answer arrives and nothing here ever waits for an
///   exit.
/// - **Different, not older.** A proxy is replaced when its version differs
///   from the binary this daemon would spawn, in either direction, because
///   `tbd update` keeps the previous app bundle as a rollback route and a
///   rollback must replace the newer image it rolled back from.
actor ModelProxySupervisor {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "model-proxy")

    /// The proxy this daemon is currently talking to.
    struct State: Sendable, Equatable {
        let pid: pid_t
        let port: Int
        /// What the proxy reports as its build identity — `ModelProxyVersion`.
        /// For one this daemon just spawned it is the daemon's own, corrected
        /// by the first watch poll if the proxy disagrees.
        let version: String
        /// True for a proxy that was already running. An adopted proxy is not
        /// this process's child, so `waitpid` can never collect it and its
        /// death is read off the process table instead.
        let adopted: Bool
    }

    enum RouteError: LocalizedError, Equatable {
        case noProxy

        var errorDescription: String? {
            switch self {
            case .noProxy:
                return "no model proxy is running for this TBD home"
            }
        }
    }

    /// How a spawn's answer relates to the persisted `model_proxy_port`.
    private enum PortDecision {
        /// Nothing is stored yet; let SQLite decide which daemon's port wins.
        case mint
        /// The stored value is known to be wrong: overwrite it.
        case overwrite
        /// The port was already stored and was asked for; persist only if the
        /// proxy somehow came back on a different one.
        case keep
    }

    private let config: ConfigStore
    private let home: URL
    private let spawner: (any ModelProxySpawning)?
    /// The identity of the `TBDModelProxy` binary this daemon would spawn, or
    /// nil when it cannot be computed — in which case no proxy is ever
    /// replaced for its version, because "differs from nothing" is not a fact.
    private let ownVersion: String?
    private let processIdentity: any ProcessIdentityChecking
    private let clientFactory: @Sendable (Int) -> ModelProxyClient
    private let watchInterval: Duration
    private let respawnBackoff: [Duration]
    private let clock: any Clock<Duration>
    private let routes: ModelProxyRouteStore

    /// The live proxy, plus the start time an adopted one reported. The anchor
    /// is not in `State` because it is only meaningful for an adopted proxy:
    /// for one we spawned, `reapIfExited` is the authority on death and no
    /// process-table reading is involved.
    private struct Live {
        var state: State
        var identityAnchor: Date?
    }

    private var live: Live?
    private var watchTask: Task<Void, Never>?
    /// Set before the first `await` in `start()`, so two concurrent starts
    /// cannot both run the startup algorithm.
    private var started = false
    /// Set by a failure respawning cannot fix — a home that cannot hold the
    /// rendezvous, or a command line this daemon composed wrong. The watch
    /// stops reconciling; only a daemon restart clears it.
    private var permanentlyDown = false
    /// Guards `replaceIfVersionDiffers` against re-entering itself through the
    /// spawn it performs.
    private var replacing = false

    init(
        config: ConfigStore,
        home: URL,
        spawner: (any ModelProxySpawning)?,
        ownVersion: String?,
        processIdentity: any ProcessIdentityChecking = ProcessTableIdentityCheck(),
        clientFactory: @escaping @Sendable (Int) -> ModelProxyClient = { ModelProxyClient(port: $0) },
        watchInterval: Duration = .seconds(15),
        respawnBackoff: [Duration] = [.seconds(1), .seconds(5), .seconds(30)],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.config = config
        self.home = home
        self.spawner = spawner
        self.ownVersion = ownVersion
        self.processIdentity = processIdentity
        self.clientFactory = clientFactory
        self.watchInterval = watchInterval
        self.respawnBackoff = respawnBackoff
        self.clock = clock
        self.routes = ModelProxyRouteStore(home: home)
    }

    /// The production wiring: the sibling `TBDModelProxy` binary, and the
    /// identity of *that exact file* as this daemon's own version.
    ///
    /// The two are computed together on purpose. Comparing a running proxy's
    /// version against anything but the file the spawner would launch is how
    /// the replacement rule goes wrong: two copies of one build have equal
    /// sizes and can differ in mtime, which reads as "replace".
    static func production(
        config: ConfigStore,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> ModelProxySupervisor {
        let executable = ModelProxySpawner.locateSiblingExecutable()
        let spawner = executable.map {
            ModelProxySpawner(executableURL: $0, environment: environment, clock: clock)
        }
        return ModelProxySupervisor(
            config: config,
            home: home,
            spawner: spawner,
            ownVersion: executable.flatMap { ModelProxyVersion.identity(of: $0) },
            clock: clock)
    }

    /// False when no `TBDModelProxy` binary sits beside this daemon, which is
    /// what `daemon.capabilities` reports as unsupported.
    var canSpawn: Bool { spawner != nil }

    var current: State? { live?.state }

    /// The base URL a session is spawned against, or nil when no proxy is
    /// current — in which case the session is spawned unproxied.
    func baseURL(for route: ModelProxyRoute) -> String? {
        guard let port = live?.state.port else { return nil }
        return "http://127.0.0.1:\(port)/r/\(route.token)"
    }

    // MARK: - Lifecycle

    /// Adopt or spawn, then start the watch. Never throws: a proxy that could
    /// not be started is a streaming nicety that is unavailable, never a
    /// daemon that failed to start.
    func start() async {
        guard !started else { return }
        started = true
        await reconcile()
        watchTask = Task { [weak self] in
            await self?.watch()
        }
    }

    /// Cancels the watch. **Does not touch the proxy**: it is meant to outlive
    /// this daemon, and a daemon restarting adopts it back through the port in
    /// the config row.
    ///
    /// The task is cancelled and not awaited. Everything the loop does between
    /// sleeps is bounded by the control client's own two-second timeout, so
    /// there is nothing a join would wait for that cancellation does not
    /// already end — and a join would need a deadline of its own.
    func stop() async {
        watchTask?.cancel()
        watchTask = nil
        started = false
    }

    private func watch() async {
        while !Task.isCancelled {
            try? await clock.sleep(for: watchInterval)
            if Task.isCancelled { return }
            await tick()
        }
    }

    // MARK: - Startup and reconciliation

    /// The startup algorithm, and the watch's answer to "there is no proxy":
    /// probe the persisted port and adopt what identifies itself, else spawn.
    private func reconcile() async {
        guard !permanentlyDown else { return }
        let persisted = await persistedPort()

        if let persisted, await adoptIfMatching(port: persisted) {
            await replaceIfVersionDiffers()
            return
        }

        if let persisted {
            await attemptSpawn(port: persisted, decision: .keep)
        } else {
            await attemptSpawn(port: 0, decision: .mint)
        }
        // Reached when a spawn adopted somebody else's proxy instead — a held
        // lock, or a bind that lost to a TBD proxy already on the port. A
        // proxy this daemon spawned reports this daemon's own version, so this
        // is a no-op on that path.
        await replaceIfVersionDiffers()
    }

    /// The stored port, or nil when none has been minted. A non-positive
    /// stored value is treated as unminted for `ensureModelProxyPort`'s
    /// reason: zero is the *ask* a proxy is spawned with, never an answer.
    private func persistedPort() async -> Int? {
        guard let stored = try? await config.get().modelProxyPort, stored > 0 else { return nil }
        return stored
    }

    /// Probes `/tbd/status` on `port` and adopts what answers, but only when
    /// the process table confirms the pid and start time it named.
    ///
    /// Returns false for every other outcome — nothing listening, an answer
    /// that is not a status document, a status document describing a process
    /// that is not there — because all three mean the same thing to the
    /// caller: this port is not holding a proxy this daemon may take over.
    private func adoptIfMatching(port: Int) async -> Bool {
        let status: ModelProxyStatus
        do {
            status = try await clientFactory(port).status()
        } catch {
            Self.logger.debug(
                """
                nothing adoptable answered /tbd/status on port \(port, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
        guard processIdentity.matches(pid: status.pid, startTime: status.processStartTime) else {
            Self.logger.error(
                """
                a process answering /tbd/status on port \(port, privacy: .public) claims pid \
                \(status.pid, privacy: .public), which the process table does not confirm; \
                not adopting it
                """)
            return false
        }
        live = Live(
            state: State(
                pid: status.pid, port: status.port > 0 ? status.port : port,
                version: status.version, adopted: true),
            identityAnchor: status.processStartTime)
        Self.logger.info(
            """
            adopted the model proxy on port \(port, privacy: .public) (pid \
            \(status.pid, privacy: .public), version \(status.version, privacy: .public))
            """)
        return true
    }

    /// One spawn, and what to do about each way it can fail.
    ///
    /// - Returns: whether a proxy is current afterwards.
    @discardableResult
    private func attemptSpawn(port requested: Int, decision: PortDecision) async -> Bool {
        guard let spawner else {
            Self.logger.info(
                """
                no model proxy binary beside this daemon; sessions for \
                \(self.home.path, privacy: .public) will not be proxied
                """)
            return false
        }

        do {
            let result = try await spawner.spawn(port: requested, home: home)
            await recordSpawn(
                pid: result.pid, port: result.port, requested: requested, decision: decision)
            return live != nil
        } catch let error as ModelProxySpawner.Error {
            return await recover(from: error, requested: requested)
        } catch {
            Self.logger.error(
                """
                could not spawn a model proxy for \(self.home.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    private func recover(from error: ModelProxySpawner.Error, requested: Int) async -> Bool {
        switch error {
        case .lockHeld:
            // A live proxy owns this rendezvous. Probe it; never unlink the
            // lock, and never spawn past it.
            // The port to probe is the one we asked for, or — on a first
            // spawn that asked the kernel — whatever another daemon has since
            // persisted.
            var probe: Int? = requested > 0 ? requested : nil
            if probe == nil { probe = await persistedPort() }
            if let probe, await adoptIfMatching(port: probe) { return true }
            Self.logger.error(
                """
                a live proxy holds the lock for \(self.home.path, privacy: .public) but nothing \
                adoptable answers on port \(probe ?? 0, privacy: .public); leaving it alone and \
                proxying no sessions
                """)
            return false

        case .bindFailed(let port):
            // Somebody has the port. A TBD proxy is adopted; anything else
            // means it was taken while TBD was stopped, and a fresh port is
            // minted (spec, "Port").
            if await adoptIfMatching(port: port) { return true }
            guard requested > 0 else {
                Self.logger.error(
                    "the model proxy could not bind a kernel-assigned port; not retrying")
                return false
            }
            Self.logger.error(
                """
                port \(port, privacy: .public) is held by something that is not a TBD proxy; \
                minting a fresh one. Sessions spawned against the old port keep it for their life
                """)
            return await attemptSpawn(port: 0, decision: .overwrite)

        case .homeUnusable:
            permanentlyDown = true
            Self.logger.error(
                """
                the model proxy's home under \(self.home.path, privacy: .public) cannot be used; \
                no session will be proxied until this daemon is restarted
                """)
            return false

        case .childExited(status: 2):
            permanentlyDown = true
            Self.logger.error(
                """
                the model proxy refused its command line (exit 2); this is a defect in the daemon \
                and respawning cannot fix it
                """)
            return false

        default:
            Self.logger.error(
                """
                could not spawn a model proxy for \(self.home.path, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    /// Records a spawned proxy and settles the persisted port.
    private func recordSpawn(
        pid: pid_t, port: Int, requested: Int, decision: PortDecision
    ) async {
        switch decision {
        case .mint:
            // SQLite decides, not this daemon: two daemons starting at once on
            // one home must agree on one port.
            do {
                let stored = try await config.ensureModelProxyPort(minting: port)
                if stored != port {
                    Self.logger.error(
                        """
                        another daemon minted port \(stored, privacy: .public) for this home while \
                        we were spawning on \(port, privacy: .public); retiring ours and adopting \
                        theirs
                        """)
                    try? await clientFactory(port).retire()
                    _ = await adoptIfMatching(port: stored)
                    return
                }
            } catch {
                Self.logger.error(
                    """
                    could not persist model proxy port \(port, privacy: .public): \
                    \(error.localizedDescription, privacy: .public); the proxy is running but a \
                    later daemon will not find it
                    """)
            }
        case .overwrite:
            try? await config.setModelProxyPort(port)
        case .keep:
            if port != requested {
                try? await config.setModelProxyPort(port)
            }
        }

        live = Live(
            state: State(
                pid: pid, port: port, version: ownVersion ?? ModelProxyVersion.unknown,
                adopted: false),
            identityAnchor: nil)
        Self.logger.info(
            """
            spawned a model proxy for \(self.home.path, privacy: .public): pid \
            \(pid, privacy: .public) on port \(port, privacy: .public)
            """)
    }

    // MARK: - Watch

    private func tick() async {
        guard !permanentlyDown else { return }
        guard let live else {
            await reconcile()
            return
        }

        // A proxy we spawned is our child, so its death is a `waitpid` away and
        // collecting it is what keeps a zombie from accumulating. An adopted
        // one is nobody's child here and this reports nothing for it.
        if !live.state.adopted, let spawner,
            let status = await spawner.reapIfExited(pid: live.state.pid)
        {
            Self.logger.error(
                """
                the model proxy (pid \(live.state.pid, privacy: .public)) exited with status \
                \(status, privacy: .public); respawning on port \(live.state.port, privacy: .public)
                """)
            self.live = nil
            await respawn(port: live.state.port)
            return
        }

        do {
            let status = try await clientFactory(live.state.port).status()
            guard processIdentity.matches(pid: status.pid, startTime: status.processStartTime)
            else {
                Self.logger.error(
                    """
                    port \(live.state.port, privacy: .public) is answering for a process this \
                    daemon does not recognise; dropping it and reconciling from scratch
                    """)
                self.live = nil
                return
            }
            // The proxy is the authority on its own version: a spawned one was
            // recorded optimistically as this daemon's, and this is where that
            // gets corrected.
            self.live = Live(
                state: State(
                    pid: status.pid, port: live.state.port, version: status.version,
                    adopted: live.state.adopted),
                identityAnchor: status.processStartTime)
            await replaceIfVersionDiffers()
        } catch {
            // A missed poll is not a death. Only the process table can tell a
            // proxy that is gone from one that is merely slow, and it is the
            // only thing consulted here.
            if live.state.adopted, let anchor = live.identityAnchor,
                !processIdentity.matches(pid: live.state.pid, startTime: anchor)
            {
                Self.logger.error(
                    """
                    the adopted model proxy (pid \(live.state.pid, privacy: .public)) is gone; \
                    respawning on port \(live.state.port, privacy: .public)
                    """)
                self.live = nil
                await respawn(port: live.state.port)
            } else {
                Self.logger.debug(
                    """
                    the model proxy on port \(live.state.port, privacy: .public) did not answer \
                    /tbd/status: \(error.localizedDescription, privacy: .public); keeping it
                    """)
            }
        }
    }

    /// One immediate attempt, then one per backoff step. Giving up is not
    /// final: the next watch tick sees no proxy and reconciles again, so the
    /// backoff bounds a burst rather than the number of attempts ever made.
    private func respawn(port: Int) async {
        if await attemptSpawn(port: port, decision: .keep) { return }
        for delay in respawnBackoff {
            if permanentlyDown || Task.isCancelled { return }
            try? await clock.sleep(for: delay)
            if permanentlyDown || Task.isCancelled { return }
            if await attemptSpawn(port: port, decision: .keep) { return }
        }
        Self.logger.error(
            """
            could not restart the model proxy after \(self.respawnBackoff.count + 1, privacy: .public) \
            attempts; the watch will try again
            """)
    }

    // MARK: - Version replacement

    /// Retires a proxy whose build differs from this daemon's and spawns a
    /// successor on the same port.
    ///
    /// `retire()` returns once the listener is closed and the rendezvous lock
    /// released, which is the moment a successor may bind — the predecessor is
    /// still draining, for up to ten minutes, and nothing here waits for it.
    private func replaceIfVersionDiffers() async {
        guard !replacing, let ownVersion, let live, live.state.version != ownVersion else {
            return
        }
        replacing = true
        defer { replacing = false }

        let port = live.state.port
        Self.logger.info(
            """
            the model proxy on port \(port, privacy: .public) reports version \
            \(live.state.version, privacy: .public) and this daemon would spawn \
            \(ownVersion, privacy: .public); retiring and replacing it
            """)
        do {
            try await clientFactory(port).retire()
        } catch {
            Self.logger.error(
                """
                the model proxy on port \(port, privacy: .public) would not retire: \
                \(error.localizedDescription, privacy: .public); leaving it in place, the watch \
                will try again
                """)
            return
        }
        self.live = nil
        await respawn(port: port)
    }

    // MARK: - Routes

    /// Writes `routes/<token>.json` and tells the proxy about it (spec,
    /// "Routes").
    ///
    /// The file is the durable half and is written first. A registration that
    /// fails is logged and not fatal: the proxy loads every file in the
    /// directory when it starts, so the route survives the proxy that missed
    /// it, and the session still has a base URL to be spawned against.
    ///
    /// - Throws: `RouteError.noProxy` when nothing is current — there is no
    ///   port to name in a base URL, so writing a route would only leave a
    ///   file nothing can serve.
    func makeRoute(
        terminalID: UUID, upstream: String, streamingEnabled: Bool
    ) async throws -> ModelProxyRoute {
        guard let live else { throw RouteError.noProxy }

        let route = ModelProxyRoute(
            token: ModelProxyRoute.mintToken(),
            terminalID: terminalID,
            upstream: upstream,
            streamingEnabled: streamingEnabled)
        try routes.write(route)

        do {
            try await clientFactory(live.state.port).addRoute(token: route.token)
        } catch {
            Self.logger.error(
                """
                the model proxy on port \(live.state.port, privacy: .public) did not accept a \
                route for terminal \(terminalID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public); the route file is written and \
                will be loaded when it next starts
                """)
        }
        return route
    }

    /// Drops a route: the proxy first, this daemon's own `unlink` behind it.
    ///
    /// The order is not a preference. A reachable proxy unlinks the route file
    /// **and** the stream file itself, and it is the only party that knows
    /// whether its tee is mid-append; unlinking behind its back would send a
    /// message's remaining deltas into an unlinked inode. Only when it cannot
    /// be asked at all do the files become the daemon's to remove.
    func retireRoute(token: String, terminalID: UUID) async {
        if let live {
            do {
                try await clientFactory(live.state.port).removeRoute(token: token)
                return
            } catch {
                Self.logger.error(
                    """
                    the model proxy on port \(live.state.port, privacy: .public) did not drop \
                    route \(token, privacy: .private): \
                    \(error.localizedDescription, privacy: .public); unlinking its files here
                    """)
            }
        }
        routes.unlink(token: token, terminalID: terminalID)
    }

    /// The token of the route naming this terminal, from one directory
    /// listing; nil when there is none.
    func routeToken(forTerminal terminalID: UUID) -> String? {
        routes.token(forTerminal: terminalID)
    }
}
