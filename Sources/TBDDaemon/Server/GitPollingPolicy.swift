import Foundation

/// Cadence policy for the daemon's always-on periodic git tasks.
///
/// The daemon sweeps every repo forever — conflict/branch status every tick,
/// plus a per-repo `git fetch`. When no TBD app is in the foreground nobody is
/// looking at conflict badges or branch freshness, so we trade latency for
/// subprocess count instead of spawning git at full speed around the clock.
///
/// Cadence choice: background is a plain multiple of foreground (6x for the
/// status sweep, 5x for fetch) — slow enough to stop the constant churn, fast
/// enough that notification-driving state (merge conflicts, remote tips) is at
/// most a minute or five stale while the app is closed or backgrounded. We
/// deliberately never stop the loops entirely: notifications must keep working
/// with no app running.
///
/// These are pure decision functions so each branch is directly testable; the
/// timer loops in `Daemon.start()` just ask for the next interval each tick.
public enum GitPollCadence {
    /// Conflict/branch status sweep interval: 10s foregrounded, 60s backgrounded.
    public static func statusInterval(isForeground: Bool) -> Duration {
        isForeground ? .seconds(10) : .seconds(60)
    }

    /// Per-repo `git fetch` interval: 60s foregrounded, 5min backgrounded.
    public static func fetchInterval(isForeground: Bool) -> Duration {
        isForeground ? .seconds(60) : .seconds(300)
    }

    /// How often the timer loops wake to re-evaluate the gated interval.
    /// Short enough that a foreground transition (or the app disappearing)
    /// changes the effective cadence within ~10s instead of one full
    /// background interval.
    public static let pollTick: Duration = .seconds(10)

    /// The daemon treats the app as foreground only while at least one client
    /// is actually connected. The reported flag alone is not trustworthy: a
    /// crashed or force-quit app never sends `isForeground: false` (the
    /// resign-active push is a fire-and-forget Task that dies with the
    /// process), which would pin the fast cadence forever with nobody
    /// watching. The app holds a long-lived state-subscription socket while
    /// running, so `connectedClients == 0` reliably means "no app".
    public static func isEffectivelyForeground(reportedForeground: Bool, connectedClients: Int) -> Bool {
        reportedForeground && connectedClients > 0
    }
}

/// Last app-reported foreground state (via the `app.setForegroundState` RPC).
///
/// Defaults to background (`false`): a freshly started daemon has no app
/// attached, so it should idle at the background cadence until an app says
/// otherwise. The app pushes its current state on every (re)connect and on
/// each `didBecomeActive`/`didResignActive` notification, so the daemon
/// converges to the right cadence as soon as an app is talking to it.
///
/// The timer loops re-evaluate this every `GitPollCadence.pollTick` while
/// waiting (see `Daemon.sleepThroughGatedInterval`), so a transition takes
/// effect within ~one tick — no sleep-cancellation plumbing needed.
public actor AppForegroundState {
    public private(set) var isForeground: Bool

    public init(isForeground: Bool = false) {
        self.isForeground = isForeground
    }

    public func set(isForeground: Bool) {
        self.isForeground = isForeground
    }
}
