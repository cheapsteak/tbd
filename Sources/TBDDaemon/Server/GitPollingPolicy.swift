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
}

/// Last app-reported foreground state (via the `app.setForegroundState` RPC).
///
/// Defaults to background (`false`): a freshly started daemon has no app
/// attached, so it should idle at the background cadence until an app says
/// otherwise. The app pushes its current state on every (re)connect and on
/// each `didBecomeActive`/`didResignActive` notification, so the daemon
/// converges to the right cadence as soon as an app is talking to it.
///
/// Note the timer loops sample this once per tick, before sleeping — a
/// foreground transition that lands mid-sleep takes effect on the next tick,
/// so the worst-case extra latency after foregrounding is one background
/// interval. That is acceptable for status freshness and keeps the loops
/// trivially simple (no sleep cancellation plumbing).
public actor AppForegroundState {
    public private(set) var isForeground: Bool

    public init(isForeground: Bool = false) {
        self.isForeground = isForeground
    }

    public func set(isForeground: Bool) {
        self.isForeground = isForeground
    }
}
