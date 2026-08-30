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

/// Identifies *which pane* holds a session registered.
///
/// Registrations are refcounted by this token, so the scheduler can tell one
/// pane's hold on a session from another's. Two things make that necessary:
/// the viewer-slot LRU permits two panes onto one session at once, and — the
/// reachable case — a pane that closes and immediately reopens tears its old
/// SwiftUI task down at an arbitrarily later moment than the new one starts,
/// so the outgoing `deregister` can land after the incoming `register`.
/// Keyed by session id alone, that late call tore down the fresh pane's
/// polling and left it silently stale.
///
/// Deliberately *not* the `Registration.generation`. The two answer opposite
/// questions: a generation must change whenever the entry becomes a new
/// incarnation, so an in-flight tick can recognise itself as stale, while a
/// token must stay stable across exactly those changes — a pane re-declaring
/// its tier is the same holder, not a second one — and must differ between two
/// panes sharing one live entry, which a single per-entry generation cannot
/// express. Minted by the pane rather than handed back by the scheduler so the
/// hold has one owner for its whole life, and `register`/`deregister` stay
/// symmetric.
struct TranscriptPaneToken: Hashable, Sendable {
    private let id: UUID
    init() { id = UUID() }
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
        /// Every pane holding this session open right now, and the tier each
        /// one declared. Held inside the entry, so it is dropped whole when the
        /// last holder leaves — nothing accumulates per retired pane.
        var holders: [TranscriptPaneToken: TranscriptPollTier]
        /// Which incarnation of this session id this registration is. Minted
        /// when the entry is created and again when its path changes — the two
        /// cases where work already in flight was computed against something
        /// this entry no longer is — so such a tick can recognise itself as
        /// stale. See `finishTick`. Holders coming and going do not mint one:
        /// the entry is still the same entry, and a tick that outlives one of
        /// several holders is still owed to the rest.
        var generation: UInt64
        var task: Task<Void, Never>?

        /// The cadence the session actually gets: the most aggressive tier any
        /// live holder declared. A session one pane is showing on screen and
        /// another is merely holding warm must poll at `.foreground` — the
        /// on-screen pane's freshness is not the other pane's to relax.
        var tier: TranscriptPollTier {
            holders.values.contains(.foreground) ? .foreground : .background
        }
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

    /// The tier a session is polled at right now, or nil when it is not
    /// registered. Read-only — the scheduler still never derives a tier from
    /// anything of its own, it only reports back the most aggressive one its
    /// holders declared.
    func registeredTier(sessionID: String) -> TranscriptPollTier? {
        registrations[sessionID]?.tier
    }

    /// How many panes are holding `sessionID` registered. Zero when it is not
    /// registered at all.
    ///
    /// Read-only, and here so a test can pin that a hold was actually released
    /// — or actually ignored, when a stale token asks. Nothing in the app reads
    /// it.
    func holderCount(sessionID: String) -> Int {
        registrations[sessionID]?.holders.count ?? 0
    }

    /// The generation of the live registration for `sessionID`, or nil when it
    /// is not registered.
    ///
    /// Read-only, and here so a test can drive `finishTick` with the same
    /// generation a real poll task carries — the stale-tick interleaving is
    /// otherwise only reachable by winning a race. Nothing in the app reads it.
    func registeredGeneration(sessionID: String) -> UInt64? {
        registrations[sessionID]?.generation
    }

    func setOnChange(_ handler: @escaping @Sendable (String) async -> Void) {
        onChange = handler
    }

    /// Adds `token`'s hold on `sessionID`, at the tier that pane declares.
    ///
    /// Idempotent per token: a pane re-declaring its tier updates its own hold
    /// rather than taking a second one, which is what makes the holder set
    /// bounded by "panes currently open", not by "tier changes ever made".
    func register(
        sessionID: String, path: String, tier: TranscriptPollTier, token: TranscriptPaneToken
    ) {
        var registration: Registration
        if let existing = registrations[sessionID] {
            registration = existing
            if registration.path != path {
                // The same session id under a different file. Whatever a tick
                // in flight built, it built against the old path; mint a new
                // incarnation so it can tell.
                lastGeneration += 1
                registration.generation = lastGeneration
                registration.path = path
            }
        } else {
            lastGeneration += 1
            registration = Registration(
                path: path, holders: [:], generation: lastGeneration, task: nil)
        }
        registration.holders[token] = tier
        registrations[sessionID] = registration
        startPolling(sessionID: sessionID)
    }

    /// Releases `token`'s hold on `sessionID`, and — only when it was the last
    /// one — stops polling **and** drops what the source built for it.
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
    ///
    /// A token that holds nothing releases nothing, and that is the whole fix
    /// for the reopen race: `TableTranscriptPaneView` deregisters when its own
    /// task observes cancellation, an arbitrarily later moment than the one
    /// SwiftUI tore it down at, so a pane that closes and immediately reopens
    /// can have its outgoing `deregister` land *after* the incoming pane's
    /// `register`. Keyed by session id alone that call tore down the live
    /// pane's polling and nothing self-corrected it; keyed by the token, the
    /// outgoing pane is simply no longer a holder and the call does nothing.
    /// The generation guard in `finishTick` does not cover this — it gates a
    /// tick, not a deregistration.
    ///
    /// Making the teardown conditional on the holder set emptying settles the
    /// two-panes-on-one-session case by the same stroke: either may leave, and
    /// the session keeps polling for whoever is left.
    func deregister(sessionID: String, token: TranscriptPaneToken) async {
        guard var registration = registrations[sessionID] else { return }
        guard registration.holders.removeValue(forKey: token) != nil else { return }
        guard registration.holders.isEmpty else {
            // Somebody is still watching. Write the shrunken holder set back
            // and re-derive the cadence: losing the on-screen pane must relax
            // the survivors to their own tier.
            registrations[sessionID] = registration
            startPolling(sessionID: sessionID)
            return
        }
        registration.task?.cancel()
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
        // Restarting a task (`setAppActive`, a re-declared tier, a holder
        // arriving or leaving) deliberately keeps the generation — the entry is
        // the same entry, only its cadence changed, and a tick in flight is
        // still owed to whoever holds it.
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
