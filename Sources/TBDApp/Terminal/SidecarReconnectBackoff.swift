import Foundation

/// When an app whose FD sidecar dropped while its RPC socket stayed up may
/// connect the sidecar again.
///
/// The daemon keeps one sidecar connection at a time, and a new connection
/// replaces the old one. Two app instances that each reconnect the moment
/// theirs drops would take it from each other on every poll, forever. So
/// every reconnect this path makes pushes the next one further out — 2 s,
/// doubling, up to 5 minutes — and the run resets only when the sidecar has
/// stayed up for 10 minutes since the last reconnect, longer than the longest
/// wait, or when the app reconnects to the daemon outright. Two instances
/// fighting therefore settle at one swap per instance every 5 minutes, and a
/// single app whose sidecar drops once reconnects at once.
///
/// "Stayed up" needs no connection identity: the only other thing that
/// reconnects the sidecar is `DaemonClient.connect()`, which resets the run
/// itself, so a sidecar found up after a reconnect this path made is either
/// that connection or one that started a fresh run.
///
/// Plain data over timestamps the caller passes in, so the pacing can be
/// tested without a clock.
struct SidecarReconnectBackoff: Sendable {
    static let initialDelay: TimeInterval = 2
    static let maximumDelay: TimeInterval = 300
    static let stableAfter: TimeInterval = 600

    /// Reconnects made since the run last reset.
    private(set) var reconnects = 0
    private var nextAllowedAt: Date?
    private var lastReconnectAt: Date?

    /// The wait after the `count`th reconnect of a run.
    static func delay(afterReconnect count: Int) -> TimeInterval {
        let doublings = min(max(count - 1, 0), 30)
        return min(initialDelay * pow(2, Double(doublings)), maximumDelay)
    }

    /// Whether a sidecar found down at `now` may be reconnected.
    func allowsReconnect(at now: Date) -> Bool {
        guard let nextAllowedAt else { return true }
        return now >= nextAllowedAt
    }

    /// Records a reconnect attempted at `now`, whether or not it connected:
    /// a daemon not listening is no reason to try faster.
    mutating func noteReconnect(at now: Date) {
        reconnects += 1
        nextAllowedAt = now.addingTimeInterval(Self.delay(afterReconnect: reconnects))
        lastReconnectAt = now
    }

    /// Records the sidecar found up at `now`. The run ends once it has stayed
    /// up for `stableAfter` since the last reconnect.
    mutating func noteConnected(at now: Date) {
        guard let lastReconnectAt, now.timeIntervalSince(lastReconnectAt) >= Self.stableAfter
        else { return }
        self = SidecarReconnectBackoff()
    }
}
