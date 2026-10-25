import Foundation

/// When an app whose FD sidecar is down may connect it again, for each of the
/// two callers that ask.
///
/// - **The poll tick** escalates. The daemon keeps one sidecar connection at a
///   time and a new connection replaces the old one, so two app instances that
///   each reconnected the moment theirs dropped would take it from each other
///   on every poll. Each reconnect the poll makes pushes its next one further
///   out — 2 s, doubling, up to 5 minutes — and the run resets only when the
///   sidecar has stayed up for 10 minutes since the last reconnect, longer
///   than the longest wait, or when the app reconnects to the daemon outright.
///   A single app whose sidecar drops once reconnects at once.
/// - **A holder attach** never escalates anything. Panels retrying through a
///   daemon restart would otherwise spend the poll's run against a vend socket
///   that is not up yet, and leave nothing allowed when it comes back. An
///   attach waits only a fixed `attachMinimumInterval` since the last
///   attach-time try, which keeps a burst of panels from all connecting at
///   once.
///
/// "Stayed up" needs no connection identity: the only other thing that
/// reconnects the sidecar is `DaemonClient.connect()`, which resets the run
/// itself, so a sidecar found up after a reconnect here is either that
/// connection or one that started a fresh run.
///
/// Timestamps are offsets on the caller's monotonic clock — `DaemonClient`
/// reads its injected clock — so a wall-clock jump cannot stall reconnects,
/// and the pacing is plain data a test can drive without one.
struct SidecarReconnectBackoff: Sendable {
    /// Which caller is asking.
    enum Caller: Sendable {
        case poll
        case attach
    }

    static let initialDelay: Duration = .seconds(2)
    static let maximumDelay: Duration = .seconds(300)
    static let stableAfter: Duration = .seconds(600)
    static let attachMinimumInterval: Duration = .seconds(1)

    /// Reconnects the poll has made since its run last reset.
    private(set) var reconnects = 0
    private var nextPollAllowedAt: Duration?
    private var lastAttachTryAt: Duration?
    private var lastReconnectAt: Duration?

    /// The poll's wait after the `count`th reconnect of a run.
    static func delay(afterReconnect count: Int) -> Duration {
        let doublings = min(max(count - 1, 0), 30)
        let delay = initialDelay * (1 << doublings)
        return min(delay, maximumDelay)
    }

    /// Whether `caller` may reconnect a sidecar found down at `now`.
    func allowsReconnect(_ caller: Caller, at now: Duration) -> Bool {
        switch caller {
        case .poll:
            guard let nextPollAllowedAt else { return true }
            return now >= nextPollAllowedAt
        case .attach:
            guard let lastAttachTryAt else { return true }
            return now - lastAttachTryAt >= Self.attachMinimumInterval
        }
    }

    /// Records a reconnect `caller` attempted at `now`, whether or not it
    /// connected: a daemon not listening is no reason to try faster.
    mutating func noteReconnect(_ caller: Caller, at now: Duration) {
        lastReconnectAt = now
        switch caller {
        case .poll:
            reconnects += 1
            nextPollAllowedAt = now + Self.delay(afterReconnect: reconnects)
        case .attach:
            lastAttachTryAt = now
        }
    }

    /// Records the sidecar found up at `now`. The poll's run ends once the
    /// sidecar has stayed up for `stableAfter` since the last reconnect.
    mutating func noteConnected(at now: Duration) {
        guard let lastReconnectAt, now - lastReconnectAt >= Self.stableAfter else { return }
        self = SidecarReconnectBackoff()
    }

    /// A clock reading as an offset from the moment this was called, so an
    /// existential clock — whose instants cannot be subtracted — can still
    /// stamp this type's timestamps.
    static func stopwatch(on clock: any Clock<Duration>) -> @Sendable () -> Duration {
        func start<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
            let origin = clock.now
            return { origin.duration(to: clock.now) }
        }
        return start(clock)
    }
}
