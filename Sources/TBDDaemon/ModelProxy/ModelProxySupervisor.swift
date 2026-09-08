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

    /// The pids this process has spawned, oldest first.
    ///
    /// `waitpid` can collect these and only these, which makes the list two
    /// things at once. A proxy answering `/tbd/status` with a pid on it is
    /// never recorded as `adopted`: that would hand its death to the process
    /// table, where nothing would ever collect it. And a pid on it that this
    /// supervisor has *dropped* must not be adopted back — `kill(pid, 0)`
    /// succeeds on a zombie and `ps` still prints its command line, so no
    /// identity check can tell an uncollected corpse of ours from a live
    /// proxy.
    ///
    /// Capped because a daemon that lives for months replaces its proxy on
    /// every `tbd update`. The cap only has to outlast the pids that are still
    /// interesting; anything evicted is older than every proxy this supervisor
    /// could still be talking to.
    private var spawnedPids: [pid_t] = []
    private static let spawnMemory = 64

    /// Spawned pids dropped without being collected, each with the reap
    /// attempts left before this supervisor stops trying.
    ///
    /// The budget is not impatience: a retired proxy drains for up to ten
    /// minutes and is legitimately still running for all of it, so at one
    /// attempt per watch tick the budget spans that. Past it, an answer of
    /// nothing forever means `ECHILD` — the child is not this process's to
    /// collect — and holding the number would only refuse a later proxy the
    /// kernel handed the same pid.
    private var pendingReap: [pid_t: Int] = [:]
    private static let reapAttemptBudget = 40

    /// One control client per port, for the life of this supervisor.
    ///
    /// The default `clientFactory` builds a `ModelProxyClient` around a fresh
    /// ephemeral `URLSession`, and the watch would otherwise call it every
    /// `watchInterval` for as long as the daemon runs — a session per tick,
    /// none of them invalidated. The cache is never evicted because its key
    /// space is the ports one home has held: one, in every install whose port
    /// is never squatted.
    private var clients: [Int: ModelProxyClient] = [:]

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

    /// Everything `daemon.capabilities` reports about the proxy, in one hop.
    ///
    /// `supported` is the conjunction rather than `canSpawn` alone: after a
    /// `homeUnusable` or a command line this daemon composed wrong, the binary
    /// is still there and `canSpawn` still answers true, while nothing will
    /// ever be routed again until the daemon restarts. Settings greys the
    /// toggle out on this fact, and it would be greyed out for the wrong reason
    /// — or not at all — if it read only half of it.
    func capabilitySnapshot() -> ModelProxyCapabilitySnapshot {
        ModelProxyCapabilitySnapshot(
            supported: canSpawn && !permanentlyDown,
            port: live?.state.port,
            version: live?.state.version)
    }

    /// The base URL a session is spawned against, or nil when no proxy is
    /// current — in which case the session is spawned unproxied.
    func baseURL(for route: ModelProxyRoute) -> String? {
        guard let port = live?.state.port else { return nil }
        return "http://127.0.0.1:\(port)/r/\(route.token)"
    }

    // MARK: - Collaborators and bookkeeping

    /// The control client for `port`, built once and kept.
    private func client(port: Int) -> ModelProxyClient {
        if let existing = clients[port] { return existing }
        let made = clientFactory(port)
        clients[port] = made
        return made
    }

    /// Records a pid this process spawned.
    private func rememberSpawned(pid: pid_t) {
        spawnedPids.removeAll { $0 == pid }
        spawnedPids.append(pid)
        if spawnedPids.count > Self.spawnMemory { spawnedPids.removeFirst() }
    }

    /// Whether this process spawned `pid`: it is ours to `waitpid`, and never
    /// something to record as adopted.
    private func weSpawned(pid: pid_t) -> Bool { spawnedPids.contains(pid) }

    /// A pid that has been collected, or given up on. It is not ours any more,
    /// and a later proxy the kernel hands the same number is adoptable again.
    private func forgetSpawned(pid: pid_t) {
        spawnedPids.removeAll { $0 == pid }
        pendingReap[pid] = nil
    }

    /// Queues one of our own children for collection.
    private func queueForReap(pid: pid_t) {
        guard weSpawned(pid: pid) else { return }
        pendingReap[pid] = Self.reapAttemptBudget
    }

    /// Drops the current proxy, queueing it for collection when it is a child
    /// of this process.
    ///
    /// **Every path that abandons a proxy goes through here.** One that did
    /// not would leave a zombie — and a zombie is adoptable, which is how a
    /// `stop()`/`start()` pair ends up holding a dead port with no branch left
    /// that would revise it.
    private func dropLive() {
        guard let live else { return }
        queueForReap(pid: live.state.pid)
        self.live = nil
    }

    /// One non-blocking `waitpid` per pid we are still waiting to collect.
    private func drainPendingReap() async {
        guard let spawner, !pendingReap.isEmpty else { return }
        for pid in Array(pendingReap.keys) {
            let reaped = await spawner.reapIfExited(pid: pid)
            // The actor suspends at that await and two passes can overlap — a
            // `stop()` sweeping while a `tick()` already in flight sweeps too.
            // So the budget is re-read here rather than carried across the
            // suspension: writing a decremented snapshot back for an entry the
            // other pass has since collected and forgotten would resurrect a
            // pid that is no longer this supervisor's, and a resurrected entry
            // refuses adoption of whatever the kernel next hands that number.
            guard let attemptsLeft = pendingReap[pid] else { continue }
            if let status = reaped {
                forgetSpawned(pid: pid)
                Self.logger.info(
                    """
                    collected the model proxy this daemon dropped (pid \(pid, privacy: .public), \
                    exit status \(status, privacy: .public))
                    """)
            } else if attemptsLeft <= 1 {
                forgetSpawned(pid: pid)
                Self.logger.error(
                    """
                    gave up collecting the model proxy this daemon dropped (pid \
                    \(pid, privacy: .public)): it is not this process's to reap
                    """)
            } else {
                pendingReap[pid] = attemptsLeft - 1
            }
        }
    }

    // MARK: - Lifecycle

    /// Adopt or spawn, then start the watch. Never throws: a proxy that could
    /// not be started is a streaming nicety that is unavailable, never a
    /// daemon that failed to start.
    func start() async {
        guard !started else { return }
        started = true
        await drainPendingReap()
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
        // The watch is what makes the next `waitpid` call, so a stop with
        // children still uncollected has to make one itself: `stop()` is not
        // only a shutdown, it is half of what flipping the runtime flag does.
        //
        // Bounded by construction — one `waitpid(WNOHANG)` per pending pid,
        // and no waiting. There is nothing to wait *for*: a retired proxy
        // drains for up to ten minutes, so a sleep long enough to matter would
        // stall every stop, and one short enough not to would change nothing.
        // What a pass does not collect stays pending for the next `start()`,
        // and is refused adoption until it is collected either way.
        await drainPendingReap()
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
            status = try await client(port: port).status()
        } catch {
            Self.logger.debug(
                """
                nothing adoptable answered /tbd/status on port \(port, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
        if pendingReap[status.pid] != nil {
            Self.logger.error(
                """
                port \(port, privacy: .public) is answering for pid \(status.pid, privacy: .public), \
                a proxy this daemon dropped and has not collected yet; not adopting our own corpse
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
        // A proxy this process spawned stays ours no matter which path found
        // it again: `adopted` is what decides whether its death is read off
        // `waitpid` or off the process table, and reading a child's off the
        // process table is how it becomes a zombie.
        let isOurChild = weSpawned(pid: status.pid)
        // Annotated rather than inferred: an unannotated ternary of two string
        // literals is ambiguous between the logger's `String` and
        // `StaticString` interpolations.
        let verb: String = isOurChild ? "took back" : "adopted"
        if live?.state.pid != status.pid { dropLive() }
        live = Live(
            state: State(
                // The port we reached it on, not the one it reported. Every
                // control call this supervisor makes goes to `port`, so a
                // status document naming a different one must not be allowed
                // to send them somewhere else.
                pid: status.pid, port: port,
                version: status.version, adopted: !isOurChild),
            identityAnchor: status.processStartTime)
        Self.logger.info(
            """
            \(verb, privacy: .public) the model proxy on port \
            \(port, privacy: .public) (pid \(status.pid, privacy: .public), version \
            \(status.version, privacy: .public))
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
        // A spawn abandons whatever was live: a proxy left behind by a
        // `stop()`/`start()` pair whose adoption did not take it back, or one
        // a `.bindFailed` recovery has just spawned past. An abandonment that
        // skips `dropLive` is a child nothing collects and a corpse
        // `adoptIfMatching` cannot refuse, which is the whole reason there is
        // one door. Before `rememberSpawned` and not after: were the kernel to
        // hand this spawn the number an adopted predecessor had just released,
        // queueing afterwards would queue the newborn.
        dropLive()
        rememberSpawned(pid: pid)

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
                        we were spawning on \(port, privacy: .public); adopting theirs and \
                        retiring ours
                        """)
                    // The winner first, and ours retired only once there is
                    // one: retiring first and failing to adopt would leave
                    // this home with no proxy at all, having just had a
                    // working one.
                    if await adoptIfMatching(port: stored) {
                        try? await client(port: port).retire()
                        queueForReap(pid: pid)
                        return
                    }
                    Self.logger.error(
                        """
                        nothing adoptable answers on port \(stored, privacy: .public); keeping the \
                        proxy spawned on \(port, privacy: .public), which a later daemon will not \
                        find
                        """)
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
            await persistPort(port)
        case .keep:
            if port != requested {
                await persistPort(port)
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

    /// Stores the port a proxy actually bound, and says so when it cannot.
    ///
    /// Not a `try?`: a failure here does not stop *this* daemon, which holds
    /// the port in memory, but it is exactly how a later one fails to find the
    /// proxy, spawns a second, and meets a held lock.
    private func persistPort(_ port: Int) async {
        do {
            try await config.setModelProxyPort(port)
        } catch {
            Self.logger.error(
                """
                could not persist model proxy port \(port, privacy: .public): \
                \(error.localizedDescription, privacy: .public); the proxy is running but a later \
                daemon will not find it
                """)
        }
    }

    // MARK: - Watch

    private func tick() async {
        // Before anything else, and even when the supervisor is permanently
        // down: a child we dropped is a zombie until somebody collects it.
        await drainPendingReap()
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
            forgetSpawned(pid: live.state.pid)
            self.live = nil
            await respawn(port: live.state.port)
            return
        }

        do {
            let status = try await client(port: live.state.port).status()
            guard processIdentity.matches(pid: status.pid, startTime: status.processStartTime)
            else {
                Self.logger.error(
                    """
                    port \(live.state.port, privacy: .public) is answering for a process this \
                    daemon does not recognise; dropping it and reconciling from scratch
                    """)
                dropLive()
                return
            }
            guard status.pid == live.state.pid else {
                // The port is serving a process other than the one recorded —
                // another daemon replaced the proxy under us, or ours went and
                // something else took the port. Moving the pid under the flag
                // the old one carried would carry two *derived* facts to a pid
                // they were never derived for: whether a death is read off
                // `waitpid` or off the process table, and whether this is a
                // corpse of ours that must be refused. Both come out of
                // `adoptIfMatching`, so the move goes through it — behind a
                // drop of the predecessor through the one door.
                Self.logger.info(
                    """
                    port \(live.state.port, privacy: .public) now answers for pid \
                    \(status.pid, privacy: .public) and not \(live.state.pid, privacy: .public); \
                    dropping the one we held and adopting afresh
                    """)
                let port = live.state.port
                dropLive()
                if await adoptIfMatching(port: port) {
                    await replaceIfVersionDiffers()
                }
                return
            }
            // The proxy is the authority on its own version: a spawned one was
            // recorded optimistically as this daemon's, and this is where that
            // gets corrected.
            self.live = Live(
                state: State(
                    pid: live.state.pid, port: live.state.port, version: status.version,
                    adopted: live.state.adopted),
                identityAnchor: status.processStartTime)
            await replaceIfVersionDiffers()
        } catch {
            // A missed poll is not a death. Only the process table can tell a
            // proxy that is gone from one that is merely slow, and it is the
            // only thing consulted here.
            //
            // For a child of ours as much as for an adopted proxy.
            // `reapIfExited` answers nothing both for a child that is still
            // running and for one this process cannot collect — `waitpid`'s
            // `ECHILD` is indistinguishable from "not exited" — so a spawned
            // proxy that consulted only `waitpid` would collapse into keep
            // forever the moment its exit went somewhere else. The anchor is
            // the start time the last answered poll recorded; with none yet,
            // there is nothing to compare and the proxy is kept.
            if let anchor = live.identityAnchor,
                !processIdentity.matches(pid: live.state.pid, startTime: anchor)
            {
                Self.logger.error(
                    """
                    the model proxy (pid \(live.state.pid, privacy: .public)) is gone from the \
                    process table; respawning on port \(live.state.port, privacy: .public)
                    """)
                dropLive()
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
            try await client(port: port).retire()
        } catch {
            Self.logger.error(
                """
                the model proxy on port \(port, privacy: .public) would not retire: \
                \(error.localizedDescription, privacy: .public); leaving it in place, the watch \
                will try again
                """)
            return
        }
        dropLive()
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
            try await client(port: live.state.port).addRoute(token: route.token)
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
                try await client(port: live.state.port).removeRoute(token: token)
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
