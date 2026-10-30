/// Reads an injected clock as the time elapsed since a starting moment.
///
/// The injected clocks in this app are existentials, `any Clock<Duration>`,
/// whose instants cannot be subtracted from one another; this opens the clock
/// once, at the start, and hands back a reading that can.
enum ClockStopwatch {
    /// Starts timing on `clock`.
    ///
    /// - Returns: How far `clock` has moved since this call, each time it is
    ///   called.
    static func start(on clock: any Clock<Duration>) -> @Sendable () -> Duration {
        func start<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
            let origin = clock.now
            return { origin.duration(to: clock.now) }
        }
        return start(clock)
    }
}
