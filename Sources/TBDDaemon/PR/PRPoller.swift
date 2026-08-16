import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRPoller")

/// Owns the periodic pull-request fetch, on the daemon's own clock.
///
/// The problem it exists to solve: `PRStatusManager.fetchAll` used to run only
/// inside the `pr.list` RPC handler, so PR facts were a side effect of an app
/// being open and polling. They stopped overnight — which is when a fleet
/// supervisor needs them most, and when the daemon is the only thing awake
/// (fleet-supervision design §2, P1 gap 1).
///
/// It owns the timer and nothing else. The pass it drives is
/// `RPCRouter.runPollPass`, which stays there because `pr.refresh` and the
/// on-select path share its enumeration helpers (`pollWorkingDirectory`,
/// `branchFacts`): an enumeration that drifted between the timer and a user
/// gesture would let a worktree be polled under one candidate list and healed
/// under another.
///
/// **This loop is the only periodic driver.** `pr.list` serves the snapshot
/// this loop produced and never fetches. That matters beyond tidiness — the
/// merged-PR transition is edge-triggered on a cache change, so whichever path
/// updates the cache consumes the edge. A second periodic driver would race for
/// it, and the loser's consumers (auto-archive, auto-hibernate-on-merge) would
/// silently never fire.
///
/// The edge itself is not owned here. It has one owner and always did:
/// `PRStatusManager.apply`, the single funnel every cache write goes through —
/// including the user-gesture `pr.refresh` path, which is aperiodic and so
/// races nothing. This type only owns the timer that calls into that funnel.
public actor PRPoller {
    /// One poll pass. Throws only on the DB enumeration failure `pr.list` used
    /// to surface to the app; forge failures are recorded as `.undetermined`
    /// observations inside the pass and never throw.
    typealias Pass = @Sendable () async throws -> Void

    /// The pass this timer drives — `RPCRouter.runPollPass`, installed at the
    /// end of the router's `init` (see `installPass`). Defaults to a no-op so a
    /// poller with nothing wired to it is inert rather than half-working.
    ///
    /// `nonisolated(unsafe)` for the same reason the router's own
    /// post-construction wiring (`mergeTrigger`, `orphanGC`, …) is: it is
    /// written exactly once, synchronously, inside the initializer of the object
    /// that owns this poller — before `start()` exists to read it and before any
    /// caller can hold a reference to tick it.
    private nonisolated(unsafe) var pass: Pass = {}
    /// Effective app-foreground gate, shared with the periodic git tasks.
    /// Wired post-construction by `Daemon.start()` (the router is built before
    /// the gate exists), defaulting to "no app" — a daemon nobody is watching
    /// should idle at the background cadence, which is also the honest starting
    /// assumption for a freshly-started daemon.
    private var isForeground: @Sendable () async -> Bool
    /// How long the gated sleep waits between re-evaluations of the interval.
    /// Injectable so a test crosses a production-sized cadence in two or three
    /// clock advances rather than thirty (`Tests/CLAUDE.md`, "keep advance
    /// chains short"); production never passes it.
    private let pollTick: Duration
    /// Delay seam (`Tests/CLAUDE.md`, "Clock and date seams"). Existential, and
    /// last, per the repo rule; the loop is pure `Duration` accumulation.
    private let clock: any Clock<Duration>

    private var loopTask: Task<Void, Never>?

    init(
        isForeground: @escaping @Sendable () async -> Bool = { false },
        pollTick: Duration = GitPollCadence.pollTick,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.isForeground = isForeground
        self.pollTick = pollTick
        self.clock = clock
    }

    // MARK: - The loop

    /// Install the pass this timer drives. Called once, from the end of
    /// `RPCRouter.init` — the closure needs a fully formed router, which does
    /// not exist while its own stored properties are still being assigned.
    ///
    /// `nonisolated` so that construction site can call it without an `await` it
    /// has no way to perform. Synchronous on purpose: hopping through a `Task`
    /// would let a caller that constructs a router and immediately ticks its
    /// poller observe the no-op default.
    nonisolated func installPass(_ pass: @escaping Pass) {
        self.pass = pass
    }

    /// Install the effective-foreground gate. MUST be called before `start()`
    /// so the first wait is already paced by a real answer.
    func setForegroundGate(_ gate: @escaping @Sendable () async -> Bool) {
        self.isForeground = gate
    }

    /// Start the periodic fetch. Idempotent — a second call is a no-op while a
    /// loop is already running.
    func start() {
        guard loopTask == nil else { return }
        let clock = self.clock
        let waitStep = self.pollTick
        // Captured strongly, not weakly: a `weak self` is an implicitly mutable
        // binding, which the nested `@Sendable` interval closure cannot capture.
        // The resulting retain cycle is broken by `stop()` (called from
        // `Daemon.stop()`), and the poller is owned by the router for the whole
        // process lifetime regardless.
        loopTask = Task { [self] in
            while !Task.isCancelled {
                await Daemon.sleepThroughGatedInterval(
                    { await currentInterval() }, tick: waitStep, clock: clock)
                guard !Task.isCancelled else { break }
                await tick()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// The interval to wait next, re-evaluated on every tick of the gated sleep
    /// so a foreground transition (or the app disappearing) changes the cadence
    /// within one tick.
    private func currentInterval() async -> Duration {
        GitPollCadence.prInterval(isForeground: await isForeground())
    }

    /// One pass of the loop.
    ///
    /// Swallows the enumeration failure `fetchOnce` throws: a tick is one of
    /// many, and the next one is already scheduled, so a transient DB error
    /// should cost a pass rather than tear down the loop.
    func tick() async {
        do {
            try await fetchOnce()
        } catch {
            // `.private`: the only thing that throws here is the DB
            // enumeration, and a GRDB error carries the failing SQL — which
            // names columns, and can carry argument values with it.
            logger.warning("PR poll skipped: \(error, privacy: .private)")
        }
    }

    // MARK: - The shared pass

    /// Drive one poll pass.
    ///
    /// Throws only on the DB enumeration failure inside the pass, which the
    /// timer logs before waiting for the next tick. Forge failures never throw —
    /// they are recorded as `.undetermined` observations inside `fetchAll`.
    func fetchOnce() async throws {
        try await pass()
    }
}
