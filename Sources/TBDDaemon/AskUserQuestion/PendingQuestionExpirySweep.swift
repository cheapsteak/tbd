import Foundation
import os
import TBDShared

/// Reaps stranded `AskUserQuestion` captures on a timer.
///
/// This ran as a side effect of `handleTerminalTranscript` until the app began
/// reading transcripts itself, at which point that handler stops being called
/// and the entries would live forever. A capture strands when a user-installed
/// PreToolUse hook blocks the tool, so no matching JSONL line ever arrives to
/// satisfy it.
///
/// The sweep owns only the timer; the reap itself is
/// `PendingQuestionStore.gcExpired`, which is also still driven by the RPC
/// handler on the flag-off path. Running both is harmless — the second pass
/// finds nothing left to reap.
actor PendingQuestionExpirySweep {

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "askUserQuestion")

    /// Unchanged from the value the RPC handler passed, so moving the sweep
    /// changes when it runs but not what it reaps.
    static let maxAge = Duration.seconds(900)

    /// Cadence. Well under `maxAge`, so the worst-case lifetime of a stranded
    /// entry is `maxAge + interval` rather than a multiple of either.
    static let interval = Duration.seconds(300)

    private let store: PendingQuestionStore
    private let now: @Sendable () -> Date
    private let onReap: @Sendable (UUID) async -> Void
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    /// - Parameter onReap: called once per terminal that lost an entry, so the
    ///   caller can publish the terminal's new (possibly empty) set. Defaults
    ///   to a no-op for tests that only care about the reap.
    init(
        store: PendingQuestionStore,
        now: @escaping @Sendable () -> Date = { Date() },
        onReap: @escaping @Sendable (UUID) async -> Void = { _ in },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.now = now
        self.onReap = onReap
        self.clock = clock
    }

    /// Reap once. Split out from the loop so a test can drive a pass without
    /// arming a timer.
    func sweepOnce() async {
        let reaped = await store.gcExpired(now: now(), maxAge: Self.maxAge)
        guard !reaped.isEmpty else { return }
        Self.log.debug("expiry sweep reaped terminals=\(reaped.count, privacy: .public)")
        for terminalID in reaped {
            await onReap(terminalID)
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await self.clock.sleep(for: Self.interval)
                if Task.isCancelled { return }
                await self.sweepOnce()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
