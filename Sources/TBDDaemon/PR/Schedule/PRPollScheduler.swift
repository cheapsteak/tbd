import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRPollScheduler")

/// Runs the PR poll schedule. Owns the timer, the in-memory schedule, and the
/// budget state; never writes PR status itself — the injected runner does.
///
/// Each wake rebuilds the schedule from injected facts, asks the governor for a
/// decision, and hands what is due to the runner. Between wakes the loop sleeps
/// until the next due time, bounded by `maxSleep` so an activity window's
/// expiry or a brake's end is noticed within that bound. A `kick()` (or a
/// `trigger(worktreeID:)`) cancels the sleep and wakes the loop at once.
///
/// Spec: docs/specs/2026-10-01-pr-polling-schedule-design.md.
public actor PRPollScheduler {
    /// The fleet's current facts, or nil when they could not be read. Nil
    /// keeps the schedule as it stands — items and due times — rather than
    /// reconciling against an empty fleet, which would drop every item and
    /// make the whole fleet due on the next good read.
    public typealias FactsProvider = @Sendable () async -> [PRPollWorktreeFacts]?
    public typealias Runner = @Sendable (PRPollDue) async -> Void

    /// The facts and the runner. Passed to `init`, or — when their owner is
    /// not fully formed yet — installed once by `installHandlers` (the
    /// `PRPoller.installPass` pattern). `nonisolated(unsafe)` for the reason
    /// `PRPoller.pass` is: written exactly once, synchronously, inside the
    /// initializer of the object that owns this scheduler, before `start()`
    /// can read it.
    private nonisolated(unsafe) var facts: FactsProvider
    private nonisolated(unsafe) var run: Runner
    /// Date seam: every due time and budget deadline is compared against this.
    private let now: @Sendable () -> Date
    private let maxSleep: Duration
    /// Delay seam (`Tests/CLAUDE.md`, "Clock and date seams"). Existential, and
    /// last, per the repo rule; only ever asked to sleep for a `Duration`.
    private let clock: any Clock<Duration>

    private var schedule = PRPollSchedule()
    private var budget = PRPollBudgetState()
    private var loopTask: Task<Void, Never>?
    /// The current inter-wake sleep. `kick()` cancels it.
    private var sleeper: Task<Void, Never>?
    /// Set by `kick()`; closes the race where a kick lands between `runOnce`
    /// returning and the sleep starting, which cancelling `sleeper` alone misses.
    private var kickPending = false
    /// True from the moment a wake hands work to the runner until `markRan`.
    private var isRunningDue = false
    /// Worktrees triggered while the runner was busy. `markRan` clears every
    /// forced due time on the items it marks, so a trigger that lands mid-run
    /// would otherwise be lost; these are re-applied right after `markRan`.
    private var triggersDuringRun: Set<UUID> = []
    /// When the projected spend was last logged at info level (once per hour).
    private var lastProjectionLog: Date?
    /// Test hook: awaited by every `kick()`.
    private var kickProbe: (@Sendable () async -> Void)?

    public init(facts: @escaping FactsProvider, run: @escaping Runner,
                now: @escaping @Sendable () -> Date = { Date() },
                maxSleep: Duration = .seconds(60),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.facts = facts
        self.run = run
        self.now = now
        self.maxSleep = maxSleep
        self.clock = clock
    }

    /// Install the facts and the runner. Called once, from the end of
    /// `RPCRouter.init` — the closures need a fully formed router, which does
    /// not exist while its own stored properties are still being assigned.
    /// `nonisolated` and synchronous so that construction site can call it
    /// without an `await`, and so no wake can observe the placeholders.
    nonisolated func installHandlers(facts: @escaping FactsProvider, run: @escaping Runner) {
        self.facts = facts
        self.run = run
    }

    public var isRunning: Bool { loopTask != nil }

    /// Start the loop. Idempotent — a second call is a no-op while a loop runs.
    public func start() {
        guard loopTask == nil else { return }
        // Captured strongly, as `PRPoller` does: the cycle is broken by `stop()`.
        loopTask = Task { [self] in
            while !Task.isCancelled {
                await runOnce()
                guard !Task.isCancelled else { break }
                await sleepUntilNextDue()
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        // The loop awaits an unstructured sleeper, which does not inherit the
        // loop's cancellation, so it is cancelled directly.
        sleeper?.cancel()
        sleeper = nil
    }

    /// Wake the loop now. `async` only so the test probe can be awaited.
    public func kick() async {
        kickPending = true
        sleeper?.cancel()
        if let kickProbe { await kickProbe() }
    }

    /// Make every item the worktree owns due now, and wake the loop.
    public func trigger(worktreeID: UUID) async {
        schedule.trigger(worktreeID: worktreeID, now: now())
        if isRunningDue { triggersDuringRun.insert(worktreeID) }
        await kick()
    }

    public func recordRateLimitSignal(_ signal: GitHubRateLimitSignal) {
        switch signal {
        case .reading(_, let remaining, let resetAt):
            budget.recordReading(remaining: remaining, resetAt: resetAt, receivedAt: now())
        case .limited:
            budget.recordRateLimitError(at: now())
        }
    }

    func setKickProbeForTests(_ probe: @escaping @Sendable () async -> Void) {
        kickProbe = probe
    }

    /// One wake: rebuild, decide, run what is due. Tests call it directly.
    ///
    /// Must not be called while the loop started by `start()` is running: the
    /// two would interleave at the runner's suspension and could hand the
    /// runner overlapping due sets. The loop and tests are its only callers.
    ///
    /// A trigger that lands while the runner is busy is replayed after
    /// `markRan`, so the item it names may run twice in a row — once in the
    /// round that was already running and once right after. That one extra
    /// point is the price of never losing a trigger.
    ///
    /// When the facts cannot be read (`FactsProvider` answers nil) the
    /// schedule is not reconciled; what is already due under it still runs.
    public func runOnce() async {
        if let current = await facts() {
            schedule.reconcile(current, now: now())
        } else {
            logger.debug("pr schedule wake: facts unreadable, keeping the current schedule")
        }
        let loads = schedule.loads()
        let decision = budget.decide(loads: loads, at: now())
        let due = schedule.due(at: now(), decision: decision)
        let projected = PRPollGovernor.projectedHourlySpend(loads, stretch: Self.stretch(of: decision))
        logger.debug("""
            pr schedule wake: \(loads.count, privacy: .public) items, \
            \(due.track.count, privacy: .public) track due, \
            \(due.discover.count, privacy: .public) discover due, \
            decision \(String(describing: decision), privacy: .public), \
            projected \(projected, privacy: .public)/h
            """)
        logProjectionHourly(projected: projected, items: loads.count, decision: decision)
        guard !due.isEmpty else { return }
        isRunningDue = true
        await run(due)
        schedule.markRan(due, at: now())
        isRunningDue = false
        let replay = triggersDuringRun
        triggersDuringRun = []
        for worktreeID in replay {
            schedule.trigger(worktreeID: worktreeID, now: now())
        }
    }

    // MARK: - Private

    private static func stretch(of decision: PRPollGovernor.Decision) -> Double {
        if case .run(let factor) = decision { return factor }
        return 1
    }

    /// `.debug` lines are not retained, and graduation needs projected spend
    /// next to the actual cost `PRStatusManager` logs per query, so the
    /// projection goes out at info level at most once an hour.
    private func logProjectionHourly(projected: Double, items: Int, decision: PRPollGovernor.Decision) {
        let current = now()
        if let last = lastProjectionLog, current.timeIntervalSince(last) < 3600 { return }
        lastProjectionLog = current
        let remaining = budget.remaining.map { String($0) } ?? "unknown"
        logger.info("""
            pr schedule projection: \(projected, privacy: .public) points/h over \
            \(items, privacy: .public) items, decision \(String(describing: decision), privacy: .public), \
            remaining \(remaining, privacy: .public)
            """)
    }

    private func sleepUntilNextDue() async {
        if kickPending {
            kickPending = false
            return
        }
        let decision = budget.decide(loads: schedule.loads(), at: now())
        var seconds = PRPollGovernor.seconds(maxSleep)
        if let next = schedule.nextDue(decision: decision) {
            seconds = min(max(next.timeIntervalSince(now()), 0), seconds)
        }
        // Something is already due (a trigger replayed after the last run):
        // wake again at once rather than asking the clock for a zero sleep.
        guard seconds > 0 else { return }
        let delay = Duration.milliseconds(Int64((seconds * 1000).rounded(.up)))
        let clock = self.clock
        let task = Task { _ = try? await clock.sleep(for: delay) }
        sleeper = task
        await task.value
        if sleeper == task { sleeper = nil }
        kickPending = false
    }
}
