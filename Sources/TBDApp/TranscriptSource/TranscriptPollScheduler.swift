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
        /// Which incarnation of this session id this registration is. Minted
        /// fresh by every `register` and never reused, so a tick that started
        /// under a registration which has since been dropped or replaced can
        /// recognise itself as stale — see `finishTick`.
        var generation: UInt64
        var task: Task<Void, Never>?
    }

    private var registrations: [String: Registration] = [:]
    /// Monotonic; the source of every `Registration.generation`. Only the live
    /// registrations hold a copy, so nothing accumulates per retired session.
    private var lastGeneration: UInt64 = 0
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

    /// The generation of the live registration for `sessionID`, or nil when it
    /// is not registered.
    ///
    /// Read-only, and here so a test can drive `finishTick` with the same token
    /// a real poll task carries — the stale-tick interleaving is otherwise only
    /// reachable by winning a race. Nothing in the app reads it.
    func registeredGeneration(sessionID: String) -> UInt64? {
        registrations[sessionID]?.generation
    }

    func setOnChange(_ handler: @escaping @Sendable (String) async -> Void) {
        onChange = handler
    }

    func register(sessionID: String, path: String, tier: TranscriptPollTier) {
        registrations[sessionID]?.task?.cancel()
        lastGeneration += 1
        registrations[sessionID] = Registration(
            path: path, tier: tier, generation: lastGeneration, task: nil)
        startPolling(sessionID: sessionID)
    }

    /// Stops polling `sessionID` **and** drops what the source built for it.
    ///
    /// The two belong together. `TranscriptSource` keeps every `TranscriptItem`
    /// it has parsed, plus `IncrementalTranscript`'s retained rows for
    /// unresolved tool calls, and nothing else in the app removes an entry — so
    /// without this the retained set is bounded only by "distinct Claude
    /// sessions ever viewed", which grows for the life of the process. Every
    /// production deregistration funnels here (`TranscriptPaneRegistration.apply`
    /// on the flag-off / no-path branch, and the live pane's `.task` teardown),
    /// which is what makes registration lifetime a real bound rather than an
    /// asserted one.
    ///
    /// The cost is that a pane which deregisters and later re-registers
    /// re-parses its file once from scratch, off the main actor. That is a
    /// single bounded read, against a daemon-poll path that re-parses the whole
    /// file every tick forever.
    ///
    /// This also covers session rollover: `/clear` and `/compact` mint a new
    /// session id, the pane's `.task(id:)` key changes, and the outgoing task
    /// deregisters the id it captured when it started — the OLD one. So the
    /// orphaned session is forgotten here too, by the same gesture.
    ///
    /// Cancelling the task does not interrupt a `refresh` it has already
    /// entered, and `forget` is a separate hop onto `TranscriptSource` with no
    /// defined order against it — so the bound above is not established here
    /// alone. `finishTick` closes that half; the removal of the registration is
    /// what it keys off.
    func deregister(sessionID: String) async {
        registrations[sessionID]?.task?.cancel()
        registrations.removeValue(forKey: sessionID)
        await source.forget(sessionID: sessionID)
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
        // Carried by the task, not re-read from `registrations` inside it: the
        // whole point is to compare against what the registry says *later*.
        // Restarting a task (`setAppActive`) deliberately keeps the generation
        // — the registration is the same one, only its cadence changed.
        let generation = registration.generation
        let interval = TranscriptPollPolicy.interval(tier: registration.tier, appActive: appActive)
        let clock = self.clock
        Self.log.debug(
            """
            polling session=\(sessionID, privacy: .public) \
            every \(String(describing: interval), privacy: .public)
            """)
        registration.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.tick(sessionID: sessionID, path: path, generation: generation)
            }
        }
        registrations[sessionID] = registration
    }

    /// One poll tick for one registration.
    ///
    /// The `Task.isCancelled` check in the loop above is not enough on its own:
    /// it can only be true *before* the refresh starts, and the refresh has no
    /// cancellation check of its own. So the generation is re-checked on both
    /// sides of it — before, to skip work a cancelled task no longer owes, and
    /// again in `finishTick`, which is where the interesting case lives.
    private func tick(sessionID: String, path: String, generation: UInt64) async {
        guard registrations[sessionID]?.generation == generation else { return }
        let change = await source.refresh(sessionID: sessionID, path: path)
        await finishTick(
            sessionID: sessionID, generation: generation,
            hasNews: !(change?.isEmpty ?? true))
    }

    /// The far side of one tick: decide whether what the refresh just did still
    /// belongs to anybody.
    ///
    /// `deregister` cancels the poll task and then forgets the session, but a
    /// refresh already in flight is not interrupted, and the two land on
    /// `TranscriptSource` in whichever order the actor happens to serialize
    /// them. When the refresh lands last it **recreates** the entry the forget
    /// just dropped, resurrecting a session nothing is registered for — exactly
    /// the bound `deregister` claims — and publishing its change would push a
    /// transcript into `AppState.sessionTranscripts` for a session the pane has
    /// already let go, where the history pane and the overlay would keep
    /// rendering it. Both halves are therefore made conditional on the
    /// generation still being the live one, rather than on winning the race.
    ///
    /// Internal, not private, so a test can drive the interleaving directly.
    func finishTick(sessionID: String, generation: UInt64, hasNews: Bool) async {
        guard registrations[sessionID]?.generation == generation else {
            // A *newer* generation for the same id keeps whatever the refresh
            // built: it is covered by a live registration, and that
            // registration's own tick reads it forward or resets it (a changed
            // path is one of `refresh`'s reset conditions). Only an absent one
            // means nothing owns the entry.
            if registrations[sessionID] == nil {
                Self.log.debug(
                    "dropping stale tick session=\(sessionID, privacy: .public)")
                await source.forget(sessionID: sessionID)
            }
            return
        }
        guard hasNews else { return }
        await onChange?(sessionID)
    }
}
