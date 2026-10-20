import Foundation
import os

/// Clears open prompts no mod is waiting on any more
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "Answering
/// prompts → Daemon: the store").
///
/// A prompt is the mod's report that a dialog is open, and only the mod can
/// end it with a receipt or a close. When the mod stops without either — it
/// reloaded mid-dialog, a close was lost, or its process died without a
/// session end — the card would otherwise stay up forever. So every
/// ``interval`` the sweep resolves `.modDisconnected` each prompt that has no
/// wait request attached and has had none attach or leave for more than
/// ``threshold`` (`PendingPromptStore.resolveIdlePrompts(now:threshold:)`),
/// and publishes the changed terminals' new sets.
///
/// Liveness is the prompt's own wait, not the terminal's poll: a dialog's
/// hook repeats its held wait for as long as the dialog is open, so a prompt
/// with no wait for a minute has nobody behind it, whatever the poll loop is
/// doing. The channel's connection state stays exposed for other consumers;
/// the sweep does not read it.
actor ModDisconnectSweep {
    static let defaultInterval: Duration = .seconds(15)
    static let defaultThreshold: Duration = .seconds(60)

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

    private let store: PendingPromptStore
    private let broadcast: @Sendable (Set<UUID>) async -> Void
    private let interval: Duration
    private let threshold: Duration
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    init(
        store: PendingPromptStore,
        broadcast: @escaping @Sendable (Set<UUID>) async -> Void,
        interval: Duration = ModDisconnectSweep.defaultInterval,
        threshold: Duration = ModDisconnectSweep.defaultThreshold,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
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
        let changed = await store.resolveIdlePrompts(now: now(), threshold: threshold)
        guard !changed.isEmpty else { return }
        for terminalID in changed {
            Self.log.debug(
                "mod disconnect sweep cleared idle prompts terminal=\(terminalID.uuidString, privacy: .public)")
        }
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
}
