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
        /// The terminal's model-proxy stream file, when the pane declared one.
        /// Nil is the ordinary case — transcript streaming off, a session that
        /// was never routed through the proxy, or a pre-streaming daemon — and
        /// means this registration never touches a second file.
        var streamPath: String?
        /// Every pane holding this session open right now, and the tier each
        /// one declared. Held inside the entry, so it is dropped whole when the
        /// last holder leaves — nothing accumulates per retired pane.
        var holders: [TranscriptPaneToken: TranscriptPollTier]
        /// Which incarnation of this session id this registration is. Minted
        /// when the entry is created and again when either of its paths changes
        /// — the cases where work already in flight was computed against
        /// something this entry no longer is — so such a tick can recognise
        /// itself as stale. See `finishTick`. Holders coming and going do not mint one:
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
    /// One handler for every registration, not one per session. It is passed
    /// the session id that changed, and it carries nothing belonging to the
    /// pane that installed it — so the first pane to mount installs it and
    /// every later one finds it already there (see ``setOnChangeIfUnset``). Do
    /// not "fix" this into a per-session dictionary; that would keep a
    /// torn-down pane's closure alive.
    private var onChange: (@Sendable (String) async -> Void)?
    private let source: TranscriptSource
    /// The instant a stream refresh stamps its lines with.
    ///
    /// A date seam rather than the clock seam beside it, because what this
    /// produces is *data*: `TranscriptSource` stores it and the provisional
    /// row's retire deadlines are later measured against it. `Duration` is
    /// behavior, `Date` is data — see the repo's clock-and-date-seam rule.
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    /// The app's one provisional-row retire timer, created with this scheduler
    /// and on its clock.
    ///
    /// It lives here because its lifetime is the *registration's*, not any
    /// pane's. An alarm is armed by a publish, and every publish in the app
    /// runs through the single ``onChange`` slot above; a pane that mounts,
    /// remounts, or is restarted by a Settings flip must therefore find the
    /// same instance the previous one armed into, or a session's live alarm
    /// ends up in one instance while the pane that would cancel it holds
    /// another — and the orphan then fires after ``deregister`` has already
    /// forgotten the session, publishing an empty transcript for it.
    /// `nonisolated` because it is an immutable `Sendable` actor reference:
    /// `publish` can take it without a hop through this actor.
    nonisolated let provisionalRetire: ProvisionalRetireTimer

    init(
        source: TranscriptSource,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.source = source
        self.now = now
        self.clock = clock
        self.provisionalRetire = ProvisionalRetireTimer(clock: clock)
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

    /// The model-proxy stream file `sessionID` is registered to tail, or nil
    /// when it has none (or is not registered at all).
    ///
    /// Read-only, and here so a test can pin what a registration actually
    /// carries rather than infer it from a tick's side effects. Nothing in the
    /// app reads it.
    func registeredStreamPath(sessionID: String) -> String? {
        registrations[sessionID]?.streamPath
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

    /// Installs the change handler, unless one is already installed.
    ///
    /// Deliberately not a plain setter. Panes call this on every mount and the
    /// closures are interchangeable — none of them carries anything belonging
    /// to the pane that built it — so re-seating one buys nothing, and the
    /// habit of re-seating it is what let a per-pane object ride into this slot
    /// and split one session's alarms across two instances. Keeping the first
    /// closure is safe: it holds `AppState` weakly, plus the same source and
    /// retire timer this scheduler already owns, and no view.
    func setOnChangeIfUnset(_ handler: @escaping @Sendable (String) async -> Void) {
        guard onChange == nil else { return }
        onChange = handler
    }

    /// Cancels the provisional retire alarm for `sessionID` — unless a pane is
    /// still holding that session registered.
    ///
    /// The guard is the whole point. The viewer-slot LRU permits two panes onto
    /// one session, and a deadline rule is announced by nothing: cancelling an
    /// alarm a surviving pane's row still depends on strands that row on screen
    /// until the pane closes. So the gesture belongs to the *last* holder
    /// leaving, and a departing pane that is not the last one asks for it in
    /// vain.
    ///
    /// ``deregister`` makes this call itself, after dropping the registration
    /// and **before** `TranscriptSource.forget` — the ordering is load-bearing.
    /// An alarm that survives into the forget wakes up, publishes what the
    /// source no longer has, and writes an empty transcript into
    /// `AppState.sessionTranscripts`, where `AppState+History.selectSession`
    /// reads `[]` as a cached answer and never refetches from disk. Session
    /// History for that session would then read empty for good.
    func disarmProvisional(sessionID: String) async {
        guard registrations[sessionID] == nil else { return }
        await provisionalRetire.disarm(sessionID: sessionID)
    }

    /// Adds `token`'s hold on `sessionID`, at the tier that pane declares.
    ///
    /// Idempotent per token: a pane re-declaring its tier updates its own hold
    /// rather than taking a second one, which is what makes the holder set
    /// bounded by "panes currently open", not by "tier changes ever made".
    ///
    /// `streamPath` is the model-proxy stream file this pane wants tailed
    /// alongside the transcript, or nil for none. It defaults to nil so a
    /// caller with no interest in streaming — every caller before this feature
    /// — reads the same as it always did.
    func register(
        sessionID: String, path: String, streamPath: String? = nil,
        tier: TranscriptPollTier, token: TranscriptPaneToken
    ) {
        var registration: Registration
        if let existing = registrations[sessionID] {
            registration = existing
            if registration.path != path || registration.streamPath != streamPath {
                // The same session id under a different file. Whatever a tick
                // in flight built, it built against the old path; mint a new
                // incarnation so it can tell. A changed stream path counts for
                // the same reason: the offsets and lines the source holds
                // describe a file this registration no longer names.
                lastGeneration += 1
                registration.generation = lastGeneration
                registration.path = path
                registration.streamPath = streamPath
            }
        } else {
            lastGeneration += 1
            registration = Registration(
                path: path, streamPath: streamPath, holders: [:],
                generation: lastGeneration, task: nil)
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
    /// on the no-path branch, and the live pane's `.task` teardown),
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
    ///
    /// The provisional retire alarm is cancelled here too, on the same
    /// last-holder branch and ahead of the forget — the only place that knows
    /// both that nobody is watching any more and that the source is about to
    /// drop what the alarm would republish. See ``disarmProvisional``.
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
        // Before the forget, never after it: see `disarmProvisional`.
        await disarmProvisional(sessionID: sessionID)
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
        let streamPath = registration.streamPath
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
                await self?.tick(
                    sessionID: sessionID, path: path, streamPath: streamPath,
                    generation: generation)
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
    ///
    /// A registration that names a stream file refreshes it in the same tick,
    /// at the same cadence: the provisional message is the same pane's content
    /// as the transcript rows, and giving it a timer of its own would be a
    /// second cadence policy to keep in step with this one. Either file
    /// changing is news — the two are folded into one `hasNews` so a stream
    /// delta with no transcript change still reaches the pane, which is the
    /// whole point of streaming.
    private func tick(
        sessionID: String, path: String, streamPath: String?, generation: UInt64
    ) async {
        guard registrations[sessionID]?.generation == generation else { return }
        let change = await source.refresh(sessionID: sessionID, path: path)
        var hasNews = !(change?.isEmpty ?? true)
        if let streamPath {
            // Not folded into the expression above: `||` short-circuits, and a
            // transcript change must not skip the stream refresh — the tail
            // would fall behind exactly when the session is busiest.
            let streamChanged = await source.refreshStream(
                sessionID: sessionID, path: streamPath, now: now())
            hasNews = hasNews || streamChanged
        }
        await finishTick(sessionID: sessionID, generation: generation, hasNews: hasNews)
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
