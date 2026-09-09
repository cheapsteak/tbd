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
    /// How this daemon signals a proxy it believes is hung — SIGTERM, then
    /// SIGKILL. Not used for anything `processIdentity` already answers; this
    /// is only ever `terminateProcessOnly`/`forceKillProcessOnly`, deliberately
    /// never the process-group form: a proxy is never `setsid`'d as a group
    /// leader the way a tmux pane is, and even if it were, only the proxy
    /// itself is this daemon's to signal.
    private let signaller: any ProcessSignaller
    private let pidFile: any ModelProxyPIDFileReading
    /// How this daemon asks who is holding a port it could not bind — a plain
    /// loopback connect, whose errno tells a transient holder of the number
    /// from a listener. See `LoopbackPortProbe` for why the control client
    /// cannot answer this question.
    private let portProbe: any LoopbackPortProbing
    /// Whether any session spawned through the proxy is still alive — one
    /// database question, asked at a boot that finds the flag off, **and on
    /// every refused bind**.
    ///
    /// The second caller is the port wait: waiting for a held port to come free
    /// is worth paying only while a session is still routed against it, because
    /// that session's `ANTHROPIC_BASE_URL` names the port for the rest of its
    /// life and minting a fresh one strands it. With nothing routed there is
    /// nothing to strand, and the wait would only delay this daemon's boot and
    /// the Settings toggle.
    ///
    /// A closure rather than a store, because it is the only thing this actor
    /// wants from the terminal table and taking the table would make the
    /// supervisor's tests need one. Its default answers "none", which is the
    /// answer that makes a supervisor with nothing injected run nothing.
    ///
    /// **It throws rather than folding an unreadable table into "none",
    /// because the two callers disagree about what an unanswered question
    /// means.** A drain-only boot that cannot read the table must start
    /// nothing: erring the other way spawns a proxy for sessions that may not
    /// exist. The port wait must assume one *is* routed and wait: erring the
    /// other way mints past a live session, which is the failure the wait
    /// exists to prevent — and a busy database is exactly the moment a
    /// contended port is being fought over. One fold here would have to pick
    /// one of those, so neither is picked here; each caller decides beside
    /// itself.
    private let routedSessionsAlive: @Sendable () async throws -> Bool
    /// This daemon's home in the one form both sides compare, computed once.
    ///
    /// `ModelProxyStatus.canonicalHome` resolves symlinks against the
    /// filesystem, and adoption asks this question on every probe; the answer
    /// cannot change while the daemon runs, so it is resolved here rather than
    /// per call.
    private let canonicalHome: String
    /// `<home>/proxy/proxy.pid` — the file the proxy writes after its bind.
    private let pidFilePath: String
    private let clientFactory: @Sendable (Int) -> ModelProxyClient
    /// How often the watch polls `/tbd/status` on the live proxy.
    ///
    /// Fifteen seconds bounds how long a dead or wedged proxy goes unnoticed
    /// against the cost of a loopback status call nobody but this daemon ever
    /// sees: fast enough that a crash is respawned well inside the timeouts a
    /// session's own retries tolerate, and slow enough that a proxy serving
    /// every session on this machine is not woken by its supervisor more
    /// often than an operator would want in `log stream`.
    private let watchInterval: Duration
    /// How long the watch waits before each respawn attempt after the proxy
    /// exits, oldest attempt first.
    ///
    /// One second, then five, then thirty: the first retry is nearly
    /// immediate because every session spawned against the dead port is
    /// itself retrying it, and Claude's own retry budget for a refused base
    /// URL is 183 seconds (spec, "Failure semantics") — comfortably wider
    /// than one exhausted burst of this ladder (1 + 5 + 30 = 36s) plus the
    /// `watchInterval` before the next one starts. The ladder then lengthens
    /// so a proxy that keeps dying on start is not respawned in a tight loop.
    /// Giving up after the last step is not permanent: `respawn` says so, and
    /// the next watch tick sees no proxy and starts a fresh burst.
    private let respawnBackoff: [Duration]
    /// How long the port wait leaves between attempts to bind a port something
    /// else is holding.
    ///
    /// Two seconds because a refused bind is cheap — the proxy exits with
    /// status 3 within milliseconds of trying — so a finer cadence would only
    /// churn processes for an answer that cannot arrive faster.
    private let portRetryInterval: Duration
    /// How many refused binds the port wait tolerates before it gives the port
    /// up and mints a fresh one.
    private let portRetryAttempts: Int
    /// The shipped cadence and count, named because their **product** is the
    /// number that has to sit between two other numbers.
    ///
    /// The window (2s × 15 = 30s) has to be wider than a transient holder
    /// typically keeps an ephemeral number. macOS hands TCP ephemeral ports out
    /// sequentially from one global counter, so a number a retiring or killed
    /// proxy just freed is often handed to an ordinary short-lived client
    /// socket before the successor binds; that socket's lifetime is sub-second
    /// to a few seconds, and 30s clears it comfortably.
    ///
    /// It also has to stay well inside the 183 seconds Claude retries a refused
    /// base URL for (spec, "Failure semantics"), measured from the *worst* path
    /// that reaches a respawn — the hang ladder, which already spends four
    /// missed polls (60s) plus `hangSignalKillDelay` ticks (30s) plus one more
    /// tick to notice the kill (15s) = 105s before the respawn starts. 105 + 30
    /// = 135s, which leaves roughly 45s for the spawn itself and a watch tick.
    static let defaultPortRetryInterval: Duration = .seconds(2)
    static let defaultPortRetryAttempts = 15
    /// Consecutive probes that find a listener — not this home's proxy, and so
    /// not adoptable — before the port is given up.
    ///
    /// A listener is not a transient: it is bound and accepting, and it will
    /// still be there in thirty seconds, so spending the whole window on it
    /// only delays the mint that has to happen anyway. Two sightings rather
    /// than one because a single accepted connect can be the tail of a holder
    /// that is closing; a second one an interval later says it is not.
    private static let foreignListenerPatience = 2
    /// Consecutive missed `/tbd/status` polls, all while the process table
    /// still confirms the proxy, before this daemon treats it as hung rather
    /// than merely slow.
    ///
    /// Four ticks at the 15s `watchInterval` is one minute — long enough that
    /// a burst of load or a GC pause on the proxy side is not mistaken for a
    /// hang, short enough that the rest of the ladder this threshold starts
    /// (SIGTERM, `hangSignalKillDelay` ticks, SIGKILL, one more tick to notice
    /// the process is gone, then a respawn inside `respawnBackoff`'s first
    /// step) finishes with comfortable room under the 183s Claude retries a
    /// refused port for.
    private static let hangSignalThreshold = 4
    /// Ticks after SIGTERM, still unresponsive, before this daemon escalates
    /// to SIGKILL.
    ///
    /// Two ticks (30s) is a real chance for a proxy that can still act on
    /// signals to exit cleanly — SIGTERM asks it to do the same
    /// close-the-listener-and-drain shutdown `POST /tbd/retire` triggers —
    /// before this daemon forces it.
    private static let hangSignalKillDelay = 2
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
    /// **The flag is off and sessions are still routed.** The supervisor keeps
    /// doing everything it does — watching, adopting, respawning — for as long
    /// as the proxy still serves a route, and retires it when the last one
    /// goes. Cleared by the flag coming back on.
    private var draining = false
    /// Route registrations that have written their file but have not yet been
    /// told to the live proxy — or, told to it and not yet answered.
    ///
    /// `makeRoute` suspends on a network call (`addRoute`) between writing the
    /// route file and the proxy knowing about it. Because this type is an
    /// actor, a `beginDraining()` triggered by a concurrent flag flip can run
    /// in that window, and the `/tbd/status` poll a drain check makes does not
    /// yet reflect a registration still in flight — both would read
    /// `routeCount == 0` and retire the proxy out from under a session that
    /// was just handed its port. Every drain check ANDs this against the
    /// polled count, so a registration in flight is treated the same as a
    /// route the proxy has already confirmed: the drain waits and the next
    /// tick tries again.
    private var routeRegistrationsInFlight = 0
    /// Consecutive `/tbd/status` failures for the live proxy, counted only
    /// while the process table still confirms its pid and start time — a
    /// failure that means "gone" instead resets this through `dropLive()`,
    /// same as any successful poll does.
    ///
    /// This is what turns a proxy that is alive but wedged — deadlocked,
    /// thread-starved, stuck in a syscall — into something the watch
    /// eventually acts on. Without it, `tick`'s poll-failure branch consults
    /// only the process table, which cannot tell "gone" from "hung", and a
    /// route whose registration failed during the hang is written to disk
    /// with no live proxy ever left to load it (see `makeRoute`'s comment
    /// on a registration failure surviving as a file for "the next start" —
    /// a wedged proxy has no next start short of this).
    private var consecutiveHungPolls = 0
    /// The value `consecutiveHungPolls` held when SIGTERM went out — nil
    /// until this hang episode's first signal. `consecutiveHungPolls` minus
    /// this is how many ticks have passed since, which is what
    /// `considerSignallingHungProxy` compares against `hangSignalKillDelay`.
    private var hangTermSentAtFailureCount: Int?
    /// Set once SIGKILL has gone out for this hang episode, so a proxy that
    /// lingers in the process table for a tick or two after being killed —
    /// an adopted proxy whose parent has not yet reaped it — is not
    /// signalled again on every subsequent tick.
    private var hangKillSent = false
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
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        pidFile: any ModelProxyPIDFileReading = ModelProxyPIDFile(),
        portProbe: any LoopbackPortProbing = LoopbackPortProbe(),
        routedSessionsAlive: @escaping @Sendable () async throws -> Bool = { false },
        clientFactory: @escaping @Sendable (Int) -> ModelProxyClient = { ModelProxyClient(port: $0) },
        watchInterval: Duration = .seconds(15),
        respawnBackoff: [Duration] = [.seconds(1), .seconds(5), .seconds(30)],
        portRetryInterval: Duration = ModelProxySupervisor.defaultPortRetryInterval,
        portRetryAttempts: Int = ModelProxySupervisor.defaultPortRetryAttempts,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.config = config
        self.home = home
        self.spawner = spawner
        self.ownVersion = ownVersion
        self.processIdentity = processIdentity
        self.signaller = signaller
        self.pidFile = pidFile
        self.portProbe = portProbe
        self.routedSessionsAlive = routedSessionsAlive
        self.canonicalHome = ModelProxyStatus.canonicalHome(home.path)
        self.pidFilePath = ProxyHomePaths(home: home).pidPath
        self.clientFactory = clientFactory
        self.watchInterval = watchInterval
        self.respawnBackoff = respawnBackoff
        self.portRetryInterval = portRetryInterval
        self.portRetryAttempts = portRetryAttempts
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
        routedSessionsAlive: @escaping @Sendable () async throws -> Bool,
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
            routedSessionsAlive: routedSessionsAlive,
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
        resetHangTracking()
    }

    /// Clears the hang-detection state — the counter and both signal
    /// markers — for whatever proxy was `live` a moment ago. Called wherever
    /// `live` stops naming that proxy (`dropLive`, the spawned-and-reaped
    /// branch of `tick`) and wherever a fresh answer proves the current one
    /// is not hung (a successful poll, a new adoption, a new spawn) — always
    /// idempotent, so calling it defensively costs nothing.
    private func resetHangTracking() {
        consecutiveHungPolls = 0
        hangTermSentAtFailureCount = nil
        hangKillSent = false
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

    /// **The gate** (spec, "The daemon" → "Supervisor" → Gate): the supervisor
    /// runs only while `config.model_proxy_enabled` is on.
    ///
    /// The one door for both the boot path and the runtime flip, so the two
    /// cannot disagree about what "enabled" means. The column is re-read here
    /// rather than passed in, because the caller that just wrote it and the
    /// caller that booted minutes ago are asking the same question and only
    /// one of them holds an answer.
    ///
    /// A config the daemon cannot read is treated as off. That is the shipped
    /// default for this flag, and starting a proxy on a failed read would be a
    /// background process nobody asked for.
    ///
    /// **Off is not always nothing.** A daemon that boots with the flag off
    /// while a session spawned under the flag is still alive starts in draining
    /// mode instead: that session's `ANTHROPIC_BASE_URL` names the proxy for
    /// the rest of its life, so somebody has to keep the port answering until
    /// it is done. An install with no such session — every install that never
    /// turned the flag on — starts nothing, which is what the success criteria
    /// mean by "no code path introduced here runs".
    func startIfEnabled() async {
        guard (try? await config.get())?.modelProxyEnabled == true else {
            await startDrainingIfSessionsAreRouted()
            return
        }
        // An on-flip while draining is a return to normal service and nothing
        // more: the watch is already running and the proxy is already this
        // supervisor's, so all that has to change is that the next tick stops
        // looking for an excuse to retire it.
        if draining {
            draining = false
            Self.logger.info(
                """
                the model proxy was switched back on for \(self.home.path, privacy: .public) \
                while it was draining; keeping the proxy and resuming normal service
                """)
        }
        await start()
    }

    /// The boot path's off branch: run only for the sessions that are already
    /// routed, and only until they are done.
    private func startDrainingIfSessionsAreRouted() async {
        guard !started else { return }
        do {
            guard try await routedSessionsAlive() else {
                Self.logger.debug(
                    """
                    the model proxy is disabled for \(self.home.path, privacy: .public) and no \
                    session is routed through it; not starting a supervisor
                    """)
                return
            }
        } catch {
            // The flag is off, so the only thing a supervisor would do here is
            // keep a proxy alive for sessions that may not exist. Starting one
            // on a question nobody answered is a background process nobody
            // asked for; the next boot asks again.
            Self.logger.error(
                """
                the model proxy is disabled for \(self.home.path, privacy: .public) and the \
                terminal table could not be read: \
                \(error.localizedDescription, privacy: .public); not starting a drain on an \
                unanswered question
                """)
            return
        }
        draining = true
        Self.logger.info(
            """
            the model proxy is disabled for \(self.home.path, privacy: .public) but sessions \
            spawned against it are still alive; supervising it until its last route retires
            """)
        await start()
    }

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

    /// Turning the flag off: **stop routing new sessions, and keep the proxy
    /// alive for the ones already routed through it.**
    ///
    /// The toggle's help text promises the flag "applies to sessions started
    /// after you change it", and the off direction has to keep that promise as
    /// literally as the on direction does. A session's `ANTHROPIC_BASE_URL` is
    /// fixed in its environment at spawn, so retiring the proxy here would not
    /// un-route those sessions — it would break them, mid-task, with a
    /// connection error to a closed loopback port and no way back short of
    /// respawning each one.
    ///
    /// So nothing is retired now. `ModelProxyRouteAttachment` already refuses
    /// to route a new spawn the moment the column reads off, which is the whole
    /// of what the user asked for; this enters **draining mode**, where the
    /// watch keeps running and the proxy keeps being adopted and respawned,
    /// and the proxy is retired only once it reports no routes left — every
    /// routed terminal having retired its own route as it exited.
    ///
    /// The immediate check is not impatience: the common case is a user with no
    /// proxied session running, and it retires the proxy in that case at the
    /// speed of the gesture rather than at the speed of the watch.
    func beginDraining() async {
        guard started || live != nil else {
            // Nothing is running, so there is nothing to drain and nothing to
            // retire. Recording draining here would arm a mode no watch would
            // ever leave.
            return
        }
        draining = true
        Self.logger.info(
            """
            the model proxy was switched off for \(self.home.path, privacy: .public); routing no \
            new session and retiring the proxy once its last route is gone
            """)
        await finishDrainingIfNoRoutesRemain(routeCount: nil)
    }

    /// One drain check. The proxy's own `routeCount` is the authority on
    /// whether any session is still routed through it — it is the party that
    /// serves them, and it rebuilds its table from `routes/` across every
    /// respawn, so it stays right through a proxy this supervisor replaced.
    ///
    /// - Parameter routeCount: the count from a status answer the caller
    ///   already holds. The watch polls `/tbd/status` every tick anyway, and a
    ///   second poll for a number that cannot have changed in between would
    ///   double the control traffic of a draining daemon. Nil asks for one.
    ///   Either way the *finish* reads it once more, because that read is the
    ///   one the retire is sent on — see `finishDraining(target:)`.
    private func finishDrainingIfNoRoutesRemain(routeCount known: Int?) async {
        guard draining, let live else {
            // Draining with no proxy current is a tick with no answer, not the
            // end of the drain: a proxy that died under a routed session is
            // respawned by the watch and rebuilds its routes from disk. The one
            // cost is an install that flips the flag off while a spawn is
            // failing, which spawns a proxy once and retires it on the next
            // tick.
            return
        }
        // The proxy this decision is about, named once. Everything after the
        // first suspension is compared against it rather than against whatever
        // `live` has become.
        let target = live
        let count: Int
        if let known {
            count = known
        } else {
            guard let polled = await routeCountFromOurProxy(target) else { return }
            count = polled
        }
        guard count == 0, routeRegistrationsInFlight == 0 else {
            Self.logger.debug(
                """
                the model proxy on port \(target.state.port, privacy: .public) still serves \
                \(count, privacy: .public) route(s) (\
                \(self.routeRegistrationsInFlight, privacy: .public) registering); draining
                """)
            return
        }
        await finishDraining(target: target)
    }

    /// `target`'s own route count, and **nil for every answer this supervisor
    /// must not act on**.
    ///
    /// A status poll is a suspension, and a drain that acts on what it learned
    /// before one has decided against a world that has since moved: the flag
    /// can come back on, a spawn can mint a route, the port can change hands.
    /// So everything the caller decided before the poll is re-read after it,
    /// and the answer itself is put through the identity checks adoption makes
    /// — this is the one status read whose verdict is a `POST /tbd/retire`, and
    /// a stranger that won the port must not be able to ask for one.
    ///
    /// Returns nil for a proxy that did not answer, too: an unanswered poll is
    /// not a route count of zero, and the drain simply tries again next tick.
    private func routeCountFromOurProxy(_ target: Live) async -> Int? {
        let status: ModelProxyStatus
        do {
            status = try await client(port: target.state.port).status()
        } catch {
            Self.logger.debug(
                """
                the draining model proxy on port \(target.state.port, privacy: .public) did not \
                answer /tbd/status: \(error.localizedDescription, privacy: .public); keeping it
                """)
            return nil
        }
        guard draining else {
            Self.logger.info(
                """
                the model proxy for \(self.home.path, privacy: .public) was switched back on while \
                its route count was being read; keeping it
                """)
            return nil
        }
        guard let current = live, current.state.pid == target.state.pid,
            current.state.port == target.state.port
        else {
            Self.logger.info(
                """
                the model proxy this drain was reading (pid \(target.state.pid, privacy: .public) \
                on port \(target.state.port, privacy: .public)) is no longer the current one; \
                leaving the decision to the next tick
                """)
            return nil
        }
        guard status.pid == target.state.pid else {
            Self.logger.error(
                """
                port \(target.state.port, privacy: .public) answered a drain check for pid \
                \(status.pid, privacy: .public) and not \(target.state.pid, privacy: .public); \
                not retiring on a stranger's route count
                """)
            return nil
        }
        if let refusal = identityRefusal(for: status, on: target.state.port) {
            Self.logger.error(
                """
                not acting on a drain check from the process answering /tbd/status on port \
                \(target.state.port, privacy: .public): \(refusal.reason, privacy: .public)
                """)
            return nil
        }
        return status.routeCount
    }

    /// The drain is over: ask the proxy to go away, then stop the watch.
    ///
    /// Retiring here and not on the flip is the difference between this and
    /// `stop()`. `stop()` is shutdown, and the proxy is meant to outlive the
    /// daemon; this is a user who does not want the feature and no longer has a
    /// session that needs it, so leaving a proxy listening, holding a lock, and
    /// self-retiring only after 24 hours would make the toggle a promise the
    /// daemon does not keep.
    ///
    /// `retire()` returns once the listener is closed and the lock released;
    /// the proxy is still draining whatever is in flight, for up to ten
    /// minutes, and nothing here waits for it.
    private func finishDraining(target: Live) async {
        // **The count is read again here, immediately before the retire, and
        // from the same identity-checked poll every other drain decision uses.**
        // The count the caller holds was true when it was read and the reads on
        // both paths are a suspension away from this line: a session spawned in
        // that window holds this proxy's port in its environment for the rest of
        // its life, and retiring the listener would break it mid-task rather
        // than un-route it — which is the whole thing draining mode exists to
        // prevent. Nothing between this call returning and the request below
        // suspends, so what it confirms is still true when the retire is sent.
        guard let remaining = await routeCountFromOurProxy(target) else { return }
        // Re-read after the suspension above, same as `remaining` itself: a
        // `makeRoute` that started before this poll and is still suspended on
        // `addRoute` counts against the retire below exactly as a confirmed
        // route would.
        guard remaining == 0, routeRegistrationsInFlight == 0 else {
            Self.logger.info(
                """
                the model proxy on port \(target.state.port, privacy: .public) took \
                \(remaining, privacy: .public) route(s) (\
                \(self.routeRegistrationsInFlight, privacy: .public) registering) while its drain \
                was finishing; keeping it
                """)
            return
        }
        // **The retire goes first, and the watch is stopped only after it
        // answers.** Two reasons, and both are load-bearing.
        //
        // `stop()` cancels the watch task, and on the tick path this runs
        // *inside* that task. Every `await` after the cancellation is a
        // cancelled await, and `ModelProxyClient` is a `URLSession` call: it
        // would throw rather than reach the proxy, and the proxy would be
        // dropped having never been asked to retire. Retiring first is what
        // makes the request happen at all.
        //
        // It is also what closes the race a snapshot across `stop()` would
        // lose. While `started` is still true a concurrent `startIfEnabled` —
        // the user flipping the flag back on — cannot reconcile or spawn
        // anything, because `start()` returns early on a supervisor that is
        // already started. So nothing can put a *different* proxy on
        // `target`'s port while this call is in flight.
        Self.logger.info(
            """
            the model proxy for \(self.home.path, privacy: .public) has no routes left; retiring \
            pid \(target.state.pid, privacy: .public) on port \
            \(target.state.port, privacy: .public)
            """)
        do {
            try await client(port: target.state.port).retire()
        } catch {
            // Nothing to fall back to, and nothing to escalate to: the proxy
            // is not this daemon's to signal on the adopted path, and on the
            // spawned path killing it would cut whatever is still in flight.
            // It self-retires after its own idle window.
            Self.logger.error(
                """
                the model proxy on port \(target.state.port, privacy: .public) would not retire: \
                \(error.localizedDescription, privacy: .public); dropping it anyway — no session \
                will be routed while the flag is off
                """)
        }
        // Asked to go away, so it stops being this supervisor's however the
        // request went. Through the one door, so a child of ours is queued for
        // collection rather than left a zombie the next `start()` would refuse
        // to adopt — and guarded on the pid, because that `retire()` is a
        // suspension of its own.
        if live?.state.pid == target.state.pid { dropLive() }
        guard draining else {
            // The flag came back on while the retire was in flight. The watch
            // stays: it finds no proxy on its next tick and reconciles a fresh
            // one, which is exactly what the on-flip asked for.
            Self.logger.info(
                """
                the model proxy for \(self.home.path, privacy: .public) was switched back on while \
                its predecessor was retiring; the watch will start a replacement
                """)
            await drainPendingReap()
            return
        }
        draining = false
        await stop()
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

    /// Why a `/tbd/status` answer is **not** this home's proxy, or nil when it
    /// is (spec, "Adoption identity").
    ///
    /// One judgment in one place, because two callers make it and they must
    /// make the same one. Adoption asks it before taking a responder over. The
    /// drain asks it before believing a `routeCount` it is about to send a
    /// `POST /tbd/retire` on — the only other place a status document decides
    /// something irreversible. A check added to one and forgotten in the other
    /// is a stranger that won the port deciding the fate of a proxy live
    /// sessions are routed through.
    ///
    /// The pid the *document* claims is not checked here: adoption has no
    /// prior pid to compare it against, and the drain has one and compares it
    /// itself. Everything else — the home, the process table, the pid file and
    /// the port in it — is asked of every caller.
    private enum IdentityRefusal {
        case noHome(pid: pid_t)
        case anotherHome(pid: pid_t, home: String)
        case processTable(pid: pid_t)
        case noPidFile(pid: pid_t)
        case pidFileNamesAnotherProcess(published: pid_t, claimed: pid_t)
        case pidFileNamesAnotherPort(published: Int, probed: Int)

        /// The clause a log line puts after naming the port that answered.
        var reason: String {
            switch self {
            case .noHome(let pid):
                return "pid \(pid) reports no home, so it is an image older than the field and "
                    + "cannot be placed"
            case .anotherHome(let pid, let home):
                return "pid \(pid) serves \(home), which is another TBD home"
            case .processTable(let pid):
                return "it claims pid \(pid), which the process table does not confirm"
            case .noPidFile(let pid):
                return "it claims pid \(pid), but this home's pid file is missing or unreadable"
            case .pidFileNamesAnotherProcess(let published, let claimed):
                return "this home's pid file names pid \(published) and it claims pid \(claimed)"
            case .pidFileNamesAnotherPort(let published, let probed):
                return "this home's pid file names port \(published), and it was reached on port "
                    + "\(probed)"
            }
        }
    }

    /// The checks above, in the order that reads best in a log line: what the
    /// document says about itself first, then the two facts on this machine
    /// that it cannot write.
    private func identityRefusal(for status: ModelProxyStatus, on port: Int) -> IdentityRefusal? {
        guard status.home.isEmpty == false else { return .noHome(pid: status.pid) }
        let answeredHome = ModelProxyStatus.canonicalHome(status.home)
        guard answeredHome == canonicalHome else {
            return .anotherHome(pid: status.pid, home: answeredHome)
        }
        guard processIdentity.matches(pid: status.pid, startTime: status.processStartTime) else {
            return .processTable(pid: status.pid)
        }
        guard let published = pidFile.read(path: pidFilePath) else {
            return .noPidFile(pid: status.pid)
        }
        guard published.pid == status.pid else {
            return .pidFileNamesAnotherProcess(published: published.pid, claimed: status.pid)
        }
        guard published.port == port else {
            return .pidFileNamesAnotherPort(published: published.port, probed: port)
        }
        return nil
    }

    /// Probes `/tbd/status` on `port` and adopts what answers, but only when
    /// four independent facts agree that the responder is this home's proxy
    /// (spec, "Adoption identity").
    ///
    /// The four are not redundant, and each closes a case the others admit:
    ///
    ///   - **The home.** Two TBD homes on one machine draw their ports from
    ///     one ephemeral range, so the kernel can hand one of them the port the
    ///     other's config row still names. Every other field would match: the
    ///     pid and start time describe a real live TBD proxy, and a
    ///     same-version install reports the same version. Only the home tells
    ///     them apart.
    ///   - **The process table.** A pid on its own is not an identity — the
    ///     kernel reissues numbers — so the start time is matched too, exactly
    ///     as `AgentReaper` does before it signals anything.
    ///   - **The pid file.** The status answer is written by whatever is
    ///     listening; the pid file is written by the process that took
    ///     `proxy.lock` and bound the port. Requiring them to agree ties the
    ///     responder to this home's rendezvous rather than trusting a payload
    ///     to describe itself.
    ///   - **The port in that file.** A pid file left by a proxy on a different
    ///     port is a rendezvous that has moved on; adopting against it would
    ///     send every later control call to a port the file does not vouch for.
    ///
    /// Returns false for every other outcome — nothing listening, an answer
    /// that is not a status document, a status document describing a process
    /// that is not there — because all of them mean the same thing to the
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
        if let refusal = identityRefusal(for: status, on: port) {
            Self.logger.error(
                """
                not adopting the process answering /tbd/status on port \(port, privacy: .public): \
                \(refusal.reason, privacy: .public)
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
        // A status answer just arrived from this exact pid, so whatever hang
        // tracking a same-pid re-adoption (the `dropLive()` above was skipped)
        // carried over is stale.
        resetHangTracking()
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
            // Somebody has the port. The port wait asks who, adopts a TBD
            // proxy, and otherwise decides between waiting the holder out and
            // minting (spec, "Port"). A kernel-assigned port has no wait to
            // run: there is no persisted number a session could be routed
            // against, so only the adoption half applies.
            guard requested > 0 else {
                if await adoptIfMatching(port: port) { return true }
                Self.logger.error(
                    "the model proxy could not bind a kernel-assigned port; not retrying")
                return false
            }
            return await reclaimPort(port)

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

    // MARK: - The port wait

    /// **The port wait** (spec, "Port"): a bounded attempt to keep the port
    /// this home's sessions are already routed against, before giving it up.
    ///
    /// The port is not a detail of this daemon's bookkeeping. It is written
    /// into every routed session's `ANTHROPIC_BASE_URL` at spawn and read once,
    /// so a session lives and dies on the number it was given: minting a fresh
    /// one strands every session on the old port, which then spends Claude's
    /// 183-second retry budget on a refused connect and fails the turn.
    ///
    /// So minting is the last answer here, not the first, and three facts have
    /// to be established before it:
    ///
    ///   - **Is it ours?** Asked first on every pass through the loop, because
    ///     a proxy that was mid-bind when this daemon's own bind lost can be
    ///     answering by the time it is probed. Adoption wins outright and costs
    ///     no wait.
    ///   - **Is it a listener or a transient?** `portProbe` answers with an
    ///     errno rather than a fold: a refused connect means nothing is
    ///     listening, so the number is held by something that will let go of it
    ///     — macOS hands ephemeral ports out sequentially from one counter, so
    ///     a number a retire or a kill just freed is routinely handed to a
    ///     short-lived client socket before the successor binds. An accepted
    ///     connect that adoption refuses is a foreign listener, which will not
    ///     let go, and is given up after `foreignListenerPatience` sightings.
    ///   - **Is anything stranded?** Asked once, and only after the first probe
    ///     has had its chance to adopt: with no session routed against the port
    ///     there is nothing to protect, and the wait would only delay this
    ///     daemon's boot and the Settings toggle.
    ///
    /// - Returns: whether a proxy is current afterwards.
    private func reclaimPort(_ port: Int) async -> Bool {
        guard let spawner else {
            Self.logger.info(
                """
                no model proxy binary beside this daemon; sessions for \
                \(self.home.path, privacy: .public) will not be proxied
                """)
            return false
        }

        // One, for the bind that brought us here.
        var refusedBinds = 1
        var listenerSightings = 0
        // The gate is one database question and its answer cannot usefully
        // change inside a 30-second window, so it is asked at most once — but
        // lazily, so an adoptable proxy on the first probe is taken without
        // asking it at all.
        var routedAnswer: Bool?

        while true {
            switch await classifyOccupant(of: port) {
            case .ours:
                return true
            case .foreignListener(let detail):
                listenerSightings += 1
                if listenerSightings >= Self.foreignListenerPatience {
                    Self.logger.error(
                        """
                        port \(port, privacy: .public) has been held across \
                        \(listenerSightings, privacy: .public) probes by a listener that is not \
                        this home's model proxy; it is not going to let go
                        """)
                    return await mintReplacement(
                        for: port, refusedBinds: refusedBinds, reason: detail)
                }
            case .transient:
                listenerSightings = 0
            }

            let routed: Bool
            if let routedAnswer {
                routed = routedAnswer
            } else {
                routed = await aSessionIsRoutedOrTheTableCannotSay(port: port)
                routedAnswer = routed
            }
            guard routed else {
                Self.logger.error(
                    """
                    port \(port, privacy: .public) is held by something that is not a TBD proxy \
                    and no session is routed against it, so nothing is stranded; minting a fresh \
                    port at once
                    """)
                return await mintReplacement(
                    for: port, refusedBinds: refusedBinds,
                    reason: "no session is routed against it")
            }

            guard refusedBinds <= portRetryAttempts else {
                Self.logger.error(
                    """
                    port \(port, privacy: .public) did not come free within \
                    \(self.portRetryAttempts, privacy: .public) attempts; giving up on it
                    """)
                return await mintReplacement(
                    for: port, refusedBinds: refusedBinds,
                    reason: "it never came free")
            }

            if permanentlyDown || Task.isCancelled { return false }
            try? await clock.sleep(for: portRetryInterval)
            // A cancelled sleep returns instantly, and a cancelled watch must
            // never mint: the daemon is going away, and the port belongs to the
            // sessions that outlive it.
            if Task.isCancelled { return false }

            do {
                let result = try await spawner.spawn(port: port, home: home)
                Self.logger.info(
                    """
                    port \(port, privacy: .public) came free after \
                    \(refusedBinds, privacy: .public) refused bind(s); the model proxy is back on it
                    """)
                await recordSpawn(
                    pid: result.pid, port: result.port, requested: port, decision: .keep)
                return live != nil
            } catch let error as ModelProxySpawner.Error {
                guard case .bindFailed = error else {
                    // Anything but another refused bind is a different question
                    // and is answered where it already is. It cannot come back
                    // here: `.bindFailed` is consumed by this loop and never
                    // reaches `recover` from this call.
                    return await recover(from: error, requested: port)
                }
                refusedBinds += 1
            } catch {
                Self.logger.error(
                    """
                    could not spawn a model proxy for \(self.home.path, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return false
            }
        }
    }

    /// The port wait's reading of the gate: **an unanswerable question counts
    /// as "yes, a session is routed".**
    ///
    /// A terminal table too busy to answer is exactly the machine on which a
    /// contended port is being fought over, so this is the moment the fold
    /// matters most — and the two mistakes do not cost the same. Waiting out a
    /// port nothing is routed against delays a boot by thirty seconds; minting
    /// past one that is strands a live session for the rest of its life. The
    /// drain-only boot reads the same failure the other way, which is why the
    /// closure throws rather than deciding for both.
    private func aSessionIsRoutedOrTheTableCannotSay(port: Int) async -> Bool {
        do {
            return try await routedSessionsAlive()
        } catch {
            Self.logger.error(
                """
                could not read whether a session is still routed against port \
                \(port, privacy: .public): \(error.localizedDescription, privacy: .public); \
                assuming one is and waiting, because minting past a routed session is the \
                failure this wait exists to prevent
                """)
            return true
        }
    }

    /// Gives the port up: mint a fresh one, overwrite the column, and say
    /// plainly what that costs.
    ///
    /// `reason` is passed in so the two ways of arriving here — a foreign
    /// listener, and a budget that ran out — share one outcome line naming both
    /// ports, which is the line an operator needs when a session that was
    /// working stops being proxied.
    private func mintReplacement(for old: Int, refusedBinds: Int, reason: String) async -> Bool {
        let minted = await attemptSpawn(port: 0, decision: .overwrite)
        guard minted, let replacement = live?.state.port else {
            Self.logger.error(
                """
                gave up on port \(old, privacy: .public) after \
                \(refusedBinds, privacy: .public) refused bind(s) \
                (\(reason, privacy: .public)) and could not mint a replacement either; \
                no session will be proxied until this daemon reconciles again
                """)
            return minted
        }
        Self.logger.error(
            """
            gave up on port \(old, privacy: .public) after \
            \(refusedBinds, privacy: .public) refused bind(s) (\(reason, privacy: .public)); \
            minted port \(replacement, privacy: .public) instead — sessions spawned against port \
            \(old, privacy: .public) keep it for their life and lose the proxy
            """)
        return minted
    }

    /// What is on the port, in the three shapes the wait branches on.
    private enum Occupant {
        /// This home's proxy, and it has just been adopted.
        case ours
        /// A listener that answered and failed the adoption identity check.
        case foreignListener(String)
        /// Nothing is listening, or the probe could not say — either way the
        /// number may come free, so it is waited on.
        case transient(String)
    }

    /// Asks the port who holds it, and lets adoption have the first word.
    ///
    /// **Adoption is tried before anything is concluded from an accepted
    /// connect**, so a proxy that came up between the failed bind and this
    /// probe is taken over rather than counted against
    /// `foreignListenerPatience`. `adoptIfMatching` already logs at `.error`
    /// *why* it refused; this adds only which of the three cases the probe saw,
    /// at `.debug`, because it is asked once per interval for the whole window.
    private func classifyOccupant(of port: Int) async -> Occupant {
        switch await portProbe.occupancy(port: port) {
        case .refused:
            Self.logger.debug(
                """
                nothing is listening on port \(port, privacy: .public); something transient holds \
                the number
                """)
            return .transient("connect refused")
        case .undetermined(let detail):
            // A bounded wait is the conservative answer to an answer we do not
            // have: waiting out a listener costs a delayed mint, while minting
            // past a transient strands live sessions.
            Self.logger.debug(
                """
                could not tell who holds port \(port, privacy: .public) \
                (\(detail, privacy: .public)); waiting it out
                """)
            return .transient(detail)
        case .accepted:
            if await adoptIfMatching(port: port) { return .ours }
            Self.logger.debug(
                """
                a listener answers on port \(port, privacy: .public) and it is not this home's \
                model proxy
                """)
            return .foreignListener("a listener that is not this home's proxy answers on it")
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
        resetHangTracking()
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
            resetHangTracking()
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
            // A real answer just arrived, so whatever this proxy's hang
            // tracking held is stale — including a SIGTERM already sent this
            // episode, since it answered after all.
            resetHangTracking()
            if draining {
                // The drain reads the count off the poll that just answered
                // rather than making a second call. A draining proxy is not
                // version-replaced either: replacing it would retire and
                // respawn a process whose only remaining job is to finish the
                // sessions it already serves.
                await finishDrainingIfNoRoutesRemain(routeCount: status.routeCount)
                return
            }
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
                // Alive by the process table and unresponsive is not a fact
                // that check can ever produce on its own — it is what
                // `consecutiveHungPolls` is counted for. Only when there is
                // an anchor to protect against a recycled pid: with none yet
                // (a just-spawned proxy's first few ticks) this daemon has
                // nothing safe to compare a signal's target against, so
                // nothing is counted or signalled until one exists.
                if let anchor = live.identityAnchor {
                    consecutiveHungPolls += 1
                    await considerSignallingHungProxy(target: live, anchor: anchor)
                }
            }
        }
    }

    /// Escalates a proxy this daemon believes is hung — alive by the process
    /// table, but has missed `hangSignalThreshold` consecutive `/tbd/status`
    /// polls in a row — from SIGTERM to SIGKILL.
    ///
    /// **Identity is re-checked immediately before every signal.** `anchor` is
    /// the start time the *last successful* poll recorded, which can be many
    /// ticks stale by the time this threshold is crossed; re-verifying against
    /// it here, right before `kill(2)`, is what keeps this from ever signalling
    /// a pid the kernel has since recycled to an unrelated process — the same
    /// discipline `AgentReaper`'s process-identity leg uses.
    private func considerSignallingHungProxy(target: Live, anchor: Date) async {
        guard consecutiveHungPolls >= Self.hangSignalThreshold else { return }
        guard processIdentity.matches(pid: target.state.pid, startTime: anchor) else {
            // Recycled or gone between the poll above and here. The death
            // path this function's caller runs alongside (or the next tick's)
            // is what handles that; there is nothing safe left to signal.
            return
        }
        if let sentAt = hangTermSentAtFailureCount {
            guard !hangKillSent else { return }
            guard consecutiveHungPolls - sentAt >= Self.hangSignalKillDelay else { return }
            Self.logger.error(
                """
                the model proxy (pid \(target.state.pid, privacy: .public)) on port \
                \(target.state.port, privacy: .public) is still unresponsive \
                \(Self.hangSignalKillDelay, privacy: .public) ticks after SIGTERM; sending SIGKILL
                """)
            signaller.forceKillProcessOnly(target.state.pid)
            hangKillSent = true
        } else {
            Self.logger.error(
                """
                the model proxy (pid \(target.state.pid, privacy: .public)) on port \
                \(target.state.port, privacy: .public) has missed \
                \(self.consecutiveHungPolls, privacy: .public) consecutive status polls; treating \
                it as hung and sending SIGTERM
                """)
            signaller.terminateProcessOnly(target.state.pid)
            hangTermSentAtFailureCount = consecutiveHungPolls
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

        // Counted from here — the file exists but the running proxy has not
        // been told about it yet — through the `addRoute` call below,
        // regardless of how it finishes. A drain that reads `/tbd/status`
        // while this suspends must not see this route as absent; see
        // `routeRegistrationsInFlight`'s doc comment.
        routeRegistrationsInFlight += 1
        defer { routeRegistrationsInFlight -= 1 }
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
