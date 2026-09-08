import Foundation

/// The one-shot alarms behind ``ProvisionalRowComposer/unconfirmedRetireAfter``
/// and ``ProvisionalRowComposer/silentStreamRetireAfter``, one per session.
///
/// Every other way a provisional row retires is announced by something the pane
/// already watches: confirmation rides in on a transcript read, an abort and a
/// newer `start` ride in on a stream-file change, and the flag going off
/// restarts the pane's loop. The two deadline rules are announced by nothing —
/// a message that has *stopped* leaves a stream file quiet by definition, and a
/// message whose proxy died mid-turn leaves one quiet in exactly the same way,
/// so the poll scheduler reports "no news" forever either way. Without an alarm
/// the row would stay on screen until some unrelated edit to the session
/// happened to trigger a publish.
///
/// So the pane arms exactly one sleep whenever it publishes a row that has a
/// deadline, and re-publishes once when it fires. The re-publish is an ordinary
/// publish: it re-reads the source and re-composes, so it retires the row by
/// simply not composing it any more, and it is correct even if the row was
/// already gone.
///
/// **One instance, keyed by session id.** `TranscriptPollScheduler` owns
/// exactly one of these and creates it with itself; panes take it from there
/// and never build one. That is not an aesthetic choice. Every publish in the
/// app runs through the scheduler's single app-wide `onChange` slot, so a pane
/// that owned its own timer would have installed a fresh instance on every
/// mount — and a second pane mounting, or a Settings flip restarting every
/// streaming pane at once, would then route a live row's *next* arm into the
/// new instance while the pane that would cancel it still held the old one.
/// The orphan fires after `TranscriptSource.forget` has run and publishes an
/// empty transcript for a session nothing is watching.
///
/// Keying the one instance by session is the other half. TBD keeps up to eight
/// panes alive at once, so an alarm armed for session A and a publish for
/// session B routinely meet inside this timer. A single-slot table would have
/// let B's ordinary transcript news — which composes no provisional row and
/// therefore takes the disarm branch — cancel A's alarm, and A's row would
/// never retire. Keying by session makes a publish for X touch only X's entry.
///
/// An actor rather than a `@MainActor` type because the pane's on-change
/// handler is `@Sendable` and runs off the main actor; only the store write at
/// the end of a publish needs main.
actor ProvisionalRetireTimer {

    private let clock: any Clock<Duration>

    /// One pending alarm: the row it belongs to, and the sleeping task.
    ///
    /// The row is identified by its message id *and* the instant it is due,
    /// never by "how long is left". A poll every 100 ms hands back the same
    /// pair and is a no-op, so the deadline cannot slide forward under
    /// repetition — `ProvisionalMessage` carries instants `TranscriptSource`
    /// holds still for exactly this reason. When a line arrives for a streaming
    /// message its due instant genuinely moves, and that is the one thing that
    /// must replace the pending alarm rather than leave it alone.
    private struct Alarm {
        let messageID: String
        let due: Date
        let task: Task<Void, Never>
    }

    /// Session id → its pending alarm. At most one alarm per session; sessions
    /// with nothing armed are absent rather than present-and-nil.
    private var alarms: [String: Alarm] = [:]

    /// Existential `Clock`, last parameter, defaulted — the repo's clock seam.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Arms a single alarm for `sessionID`'s `messageID`, due at `deadline` and
    /// firing `after` from now.
    ///
    /// Idempotent per session, message id and deadline: re-arming the pair
    /// already armed on that session leaves the existing alarm exactly where it
    /// is. A *different* id, or the same id whose deadline has moved, cancels
    /// that session's old alarm first — the first because the row it belonged
    /// to is no longer the row on screen, the second because a streaming row
    /// that has just received a line is owed a later wake-up than the one
    /// pending. Other sessions' alarms are untouched in every case.
    ///
    /// `deadline` is the alarm's identity, not a clock this actor reads: the
    /// sleep is `after` on the injected clock, so a test clock never has to
    /// agree with `Date`.
    func arm(
        sessionID: String,
        messageID: String,
        deadline: Date,
        after: Duration,
        fire: @escaping @Sendable () async -> Void
    ) {
        if let pending = alarms[sessionID],
           pending.messageID == messageID, pending.due == deadline { return }
        alarms[sessionID]?.task.cancel()
        let clock = self.clock
        alarms[sessionID] = Alarm(
            messageID: messageID,
            due: deadline,
            task: Task { [weak self] in
                try? await clock.sleep(for: after)
                guard !Task.isCancelled else { return }
                await self?.clear(sessionID: sessionID, messageID: messageID, due: deadline)
                await fire()
            })
    }

    /// Cancels whatever is armed **for this session only**. Called on every
    /// publish that does not produce a row with a deadline for it — the row was
    /// confirmed, aborted, superseded or switched off — and once more when the
    /// last pane holding the session lets it go, through
    /// `TranscriptPollScheduler.disarmProvisional`. A publish for one session
    /// must never disturb another's alarm, which is the whole reason this takes
    /// a session id.
    func disarm(sessionID: String) {
        alarms.removeValue(forKey: sessionID)?.task.cancel()
    }

    /// Cancels every alarm this timer holds.
    ///
    /// For tests, and for a caller that really is tearing down *everything*
    /// this timer serves. **Not** for a pane's own teardown: one instance
    /// serves the whole app, so the table holds alarms for sessions other panes
    /// are showing, and cancelling one of those strands its provisional row on
    /// screen — a deadline rule is announced by nothing, so nothing re-arms it.
    /// A pane leaving goes through
    /// `TranscriptPollScheduler.disarmProvisional(sessionID:)`, which reaches
    /// ``disarm(sessionID:)`` for that one session and only once nobody holds
    /// it any more.
    func disarmAll() {
        for alarm in alarms.values { alarm.task.cancel() }
        alarms.removeAll()
    }

    /// The message id currently armed for `sessionID`, or nil. Read-only, for
    /// tests — the same shape as `TranscriptPollScheduler`'s test accessors.
    func armedMessage(sessionID: String) -> String? { alarms[sessionID]?.messageID }

    /// How many sessions have an alarm pending. Read-only, for tests, so the
    /// "a publish for B armed nothing of its own" half of the two-session case
    /// is a claim about the whole table rather than about one lookup.
    var armedSessionCount: Int { alarms.count }

    /// Clears the record of an alarm that has just fired, unless a later `arm`
    /// already replaced it for that session — a replacement being either a
    /// different message or the same message with a deadline that has moved.
    private func clear(sessionID: String, messageID: String, due: Date) {
        guard let pending = alarms[sessionID],
              pending.messageID == messageID, pending.due == due else { return }
        alarms.removeValue(forKey: sessionID)
    }
}
