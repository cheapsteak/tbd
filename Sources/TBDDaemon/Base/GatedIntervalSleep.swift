/// Sleep in `tick`-sized steps (the daemon's loops pass `GitPollCadence.pollTick`) until the
/// gated interval has elapsed. `interval` is re-evaluated every tick, so a foreground
/// transition or app disconnect changes the effective cadence within one
/// tick instead of one full background interval (e.g. after a daemon
/// restart under a foregrounded app, the first fetch still lands at ~60s
/// rather than the 5min sampled before the app reconnected). Returns
/// promptly on task cancellation.
///
/// - Parameters:
///   - tick: how long to wait between re-evaluations of `interval`.
///     Injectable so a test can cross a threshold in two or three clock
///     advances instead of a production-sized chain.
///   - clock: delay seam (`Tests/CLAUDE.md`, "Clock and date seams"). This
///     loop is pure `Duration` accumulation, so the existential's inability
///     to express `Instant` math never bites.
func sleepThroughGatedInterval(
    _ interval: @Sendable () async -> Duration,
    tick: Duration,
    clock: any Clock<Duration> = ContinuousClock()
) async {
    var waited = Duration.zero
    while !Task.isCancelled {
        // `try?` swallows the cancellation error rather than checking for it;
        // the loop head is what observes cancellation. A cancelled sleep
        // therefore costs one extra `interval()` evaluation, which is
        // side-effect-free today. That stops holding if `interval` ever gains
        // side effects or if the `while` condition stops re-checking
        // `Task.isCancelled`.
        try? await clock.sleep(for: tick)
        waited += tick
        let due = await interval()
        if waited >= due { return }
    }
}
