import Foundation
import os
import TBDShared

/// Which cadence a registered session deserves. Panes declare this; the
/// scheduler does not derive it, so it carries no panel-surface knowledge and
/// is testable without constructing a workspace surface.
enum TranscriptPollTier: Sendable, Equatable {
    /// On screen right now.
    case foreground
    /// Alive but not visible — a background tab, or a pane the viewer-slot LRU
    /// is still holding.
    case background
}

/// The cadence policy, as a pure function so it can be asserted without timing.
enum TranscriptPollPolicy {
    static let foreground = Duration.milliseconds(100)
    static let background = Duration.seconds(2)
    static let inactive = Duration.seconds(10)

    /// An inactive app overrides the tier entirely. A backgrounded TBDApp has
    /// its delayed work coalesced by App Nap regardless, so a 100ms timer buys
    /// no freshness there and only enlarges the wake-up burst. Stating the
    /// cadence beats inheriting one.
    static func interval(tier: TranscriptPollTier, appActive: Bool) -> Duration {
        guard appActive else { return inactive }
        switch tier {
        case .foreground: return foreground
        case .background: return background
        }
    }
}

/// Drives `TranscriptSource.refresh` for every registered session at its tier's
/// cadence. One task per registration; nothing unregistered is ever stat'd.
actor TranscriptPollScheduler {

    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-source")

    private struct Registration {
        var path: String
        var tier: TranscriptPollTier
        var task: Task<Void, Never>?
    }

    private var registrations: [String: Registration] = [:]
    private var appActive = true
    /// One handler for every registration, not one per session. Each pane sets
    /// the same closure and it is passed the session id that changed, so a
    /// later pane overwriting an earlier one's handler is harmless — they are
    /// interchangeable. Do not "fix" this into a per-session dictionary; that
    /// would keep a torn-down pane's closure alive.
    private var onChange: (@Sendable (String) async -> Void)?
    private let source: TranscriptSource
    private let clock: any Clock<Duration>

    init(source: TranscriptSource, clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        self.clock = clock
    }

    var registeredSessionIDs: Set<String> { Set(registrations.keys) }

    /// The tier a session is registered at right now, or nil when it is not
    /// registered. Read-only — the scheduler still never derives a tier, it
    /// only reports back the one the pane declared.
    func registeredTier(sessionID: String) -> TranscriptPollTier? {
        registrations[sessionID]?.tier
    }

    func setOnChange(_ handler: @escaping @Sendable (String) async -> Void) {
        onChange = handler
    }

    func register(sessionID: String, path: String, tier: TranscriptPollTier) {
        registrations[sessionID]?.task?.cancel()
        registrations[sessionID] = Registration(path: path, tier: tier, task: nil)
        startPolling(sessionID: sessionID)
    }

    func deregister(sessionID: String) {
        registrations[sessionID]?.task?.cancel()
        registrations.removeValue(forKey: sessionID)
    }

    func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        for sessionID in registrations.keys { startPolling(sessionID: sessionID) }
    }

    private func startPolling(sessionID: String) {
        guard var registration = registrations[sessionID] else { return }
        registration.task?.cancel()
        let path = registration.path
        let interval = TranscriptPollPolicy.interval(tier: registration.tier, appActive: appActive)
        let clock = self.clock
        let source = self.source
        Self.log.debug(
            """
            polling session=\(sessionID, privacy: .public) \
            every \(String(describing: interval), privacy: .public)
            """)
        registration.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                if Task.isCancelled { return }
                let change = await source.refresh(sessionID: sessionID, path: path)
                if let change, !change.isEmpty {
                    await self?.notifyChange(sessionID)
                }
            }
        }
        registrations[sessionID] = registration
    }

    private func notifyChange(_ sessionID: String) async {
        await onChange?(sessionID)
    }
}
