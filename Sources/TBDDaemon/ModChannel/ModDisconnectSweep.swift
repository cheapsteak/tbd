import Foundation
import os

/// Clears the open prompts of terminals whose session mod stopped polling
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Answering
/// prompts → Clearing").
///
/// A prompt is the mod's report that a dialog is open, and only the mod can
/// end it with a receipt or a close. When the mod goes away without either —
/// it reloaded mid-dialog, or its process died without a session end — the
/// card would otherwise stay up forever. So every ``interval`` the sweep
/// resolves `.modDisconnected` the prompts of each terminal that is not
/// connected (`ModChannel.isConnected`) and whose reference time is more than
/// ``threshold`` old, and publishes the terminal's new set.
///
/// The reference time is the terminal's last poll, or — for a terminal that
/// never polled this daemon run — its newest prompt's `createdAt`, so a prompt
/// is never swept before its mod has had the full threshold to show up. That
/// matters after a daemon restart: the mod re-posts its open dialogs on the
/// same reconnect that starts its polls, and a terminal the new daemon has
/// not yet seen poll must not lose a prompt opened a moment ago.
actor ModDisconnectSweep {
    static let defaultInterval: Duration = .seconds(15)
    static let defaultThreshold: Duration = .seconds(60)

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

    private let channel: ModChannel
    private let store: PendingPromptStore
    private let broadcast: @Sendable (Set<UUID>) async -> Void
    private let interval: Duration
    private let threshold: Duration
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    init(
        channel: ModChannel,
        store: PendingPromptStore,
        broadcast: @escaping @Sendable (Set<UUID>) async -> Void,
        interval: Duration = ModDisconnectSweep.defaultInterval,
        threshold: Duration = ModDisconnectSweep.defaultThreshold,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.channel = channel
        self.store = store
        self.broadcast = broadcast
        self.interval = interval
        self.threshold = threshold
        self.now = now
        self.clock = clock
    }

    /// One pass. Split out from the loop so a test can drive it without
    /// arming a timer.
    func sweepOnce() async {
        let thresholdSeconds = Self.seconds(threshold)
        var changed: Set<UUID> = []
        for terminalID in await store.terminalsWithOpenPrompts() {
            if await channel.isConnected(terminalID: terminalID) { continue }
            let reference: Date?
            if let lastPoll = await channel.lastPollAt(terminalID: terminalID) {
                reference = lastPoll
            } else {
                reference = await store.prompts(forTerminal: terminalID).map(\.createdAt).max()
            }
            guard let reference, now().timeIntervalSince(reference) > thresholdSeconds else { continue }
            let resolved = await store.resolvePrompts(terminalID: terminalID, .modDisconnected)
            if !resolved.isEmpty {
                Self.log.debug(
                    "mod disconnect sweep cleared prompts terminal=\(terminalID.uuidString, privacy: .public)")
            }
            changed.formUnion(resolved)
        }
        guard !changed.isEmpty else { return }
        await broadcast(changed)
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, clock, interval] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.sweepOnce()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
