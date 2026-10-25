import Foundation

/// When an app whose FD sidecar is down may connect it again, for each of the
/// two callers that ask. Each caller has a backoff of its own.
///
/// The daemon keeps one sidecar connection at a time and a new connection
/// replaces the old one, so two app instances that each reconnected the
/// moment theirs dropped would take it from each other forever. Both callers
/// therefore escalate, each on its own run:
///
/// - **The poll tick** waits 2 s after its first reconnect, doubling up to 5
///   minutes. Its run resets only when the sidecar has stayed up for 10
///   minutes since the last reconnect — longer than the longest wait — or
///   when the app reconnects to the daemon outright.
/// - **A holder attach** waits 1 s, doubling up to 30 s, so a second instance
///   taking the sidecar on every attach is slowed down rather than fought
///   tab by tab. Its run resets when an attach is delivered, which a
///   reconnect that was taken away again cannot produce.
///
/// The runs are kept apart so panels retrying through a daemon restart, whose
/// tries fail against a vend socket that is not up yet, cannot use up the
/// poll's run and leave it unable to reconnect when the socket comes back.
/// Either caller's first reconnect after a reset is immediate.
///
/// "Stayed up" needs no connection identity: the only other thing that
/// reconnects the sidecar is `DaemonClient.connect()`, which resets everything
/// itself, so a sidecar found up after a reconnect here is either that
/// connection or one that started afresh.
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
    static let attachInitialDelay: Duration = .seconds(1)
    static let attachMaximumDelay: Duration = .seconds(30)

    /// Reconnects the poll has made since its run last reset.
    private(set) var reconnects = 0
    /// Reconnects attaches have made since their run last reset.
    private(set) var attachReconnects = 0
    private var nextPollAllowedAt: Duration?
    private var nextAttachAllowedAt: Duration?
    private var lastReconnectAt: Duration?

    /// The poll's wait after the `count`th reconnect of a run.
    static func delay(afterReconnect count: Int) -> Duration {
        doubling(initialDelay, upTo: maximumDelay, steps: count - 1)
    }

    /// An attach's wait after the `count`th attach-time reconnect of a run.
    static func attachDelay(afterReconnect count: Int) -> Duration {
        doubling(attachInitialDelay, upTo: attachMaximumDelay, steps: count - 1)
    }

    private static func doubling(_ initial: Duration, upTo maximum: Duration, steps: Int) -> Duration {
        let doublings = min(max(steps, 0), 30)
        return min(initial * (1 << doublings), maximum)
    }

    /// Whether `caller` may reconnect a sidecar found down at `now`.
    func allowsReconnect(_ caller: Caller, at now: Duration) -> Bool {
        let nextAllowedAt = caller == .poll ? nextPollAllowedAt : nextAttachAllowedAt
        guard let nextAllowedAt else { return true }
        return now >= nextAllowedAt
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
            attachReconnects += 1
            nextAttachAllowedAt = now + Self.attachDelay(afterReconnect: attachReconnects)
        }
    }

    /// Records the sidecar found up at `now`. Both runs end once it has
    /// stayed up for `stableAfter` since the last reconnect.
    mutating func noteConnected(at now: Duration) {
        guard let lastReconnectAt, now - lastReconnectAt >= Self.stableAfter else { return }
        self = SidecarReconnectBackoff()
    }

    /// Records a delivered holder attach: the attach run ends.
    mutating func noteAttachDelivered() {
        attachReconnects = 0
        nextAttachAllowedAt = nil
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
