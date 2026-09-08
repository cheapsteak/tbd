import Foundation

/// The one-shot alarms behind ``ProvisionalRowComposer/unconfirmedRetireAfter``,
/// one per session.
///
/// Every other way a provisional row retires is announced by something the pane
/// already watches: confirmation rides in on a transcript read, an abort and a
/// newer `start` ride in on a stream-file change, and the flag going off
/// restarts the pane's loop. The 60-second rule is announced by nothing —
/// the message has *stopped*, so the stream file has gone quiet by definition
/// and the poll scheduler will report "no news" forever. Without an alarm the
/// row would stay on screen until some unrelated edit to the session happened
/// to trigger a publish.
///
/// So the pane arms exactly one sleep when it publishes a `.complete` row, and
/// re-publishes once when it fires. The re-publish is an ordinary publish: it
/// re-reads the source and re-composes, so it retires the row by simply not
/// composing it any more, and it is correct even if the row was already gone.
///
/// **Why the state is keyed by session id.** One instance of this actor is
/// created per run of `appSideLoop`, but the closure that carries it is
/// installed into `TranscriptPollScheduler`'s single app-wide `onChange` slot —
/// whichever pane registered last wins, and every session's publish then runs
/// through that one instance. TBD keeps up to eight panes alive at once, so an
/// alarm armed for session A and a publish for session B routinely meet inside
/// the same timer. A single-slot timer would have let B's ordinary transcript
/// news — which composes no provisional row and therefore takes the disarm
/// branch — cancel A's alarm, and A's row would never retire. Keying by session
/// makes a publish for X touch only X's entry.
///
/// An actor rather than a `@MainActor` type because the pane's on-change
/// handler is `@Sendable` and runs off the main actor; only the store write at
/// the end of a publish needs main.
actor ProvisionalRetireTimer {

    private let clock: any Clock<Duration>

    /// One pending alarm: the message id it belongs to, and the sleeping task.
    ///
    /// Recorded by message id, not by deadline, so a poll every 100 ms
    /// re-arming for the same message is a no-op rather than a deadline that
    /// keeps sliding forward — the same reason `TranscriptSource` records the
    /// completion instant once.
    private struct Alarm {
        let messageID: String
        let task: Task<Void, Never>
    }

    /// Session id → its pending alarm. At most one alarm per session; sessions
    /// with nothing armed are absent rather than present-and-nil.
    private var alarms: [String: Alarm] = [:]

    /// Existential `Clock`, last parameter, defaulted — the repo's clock seam.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Arms a single alarm for `sessionID`'s `messageID`, firing `after` from
    /// now.
    ///
    /// Idempotent per session and message id: re-arming for the id already
    /// armed on that session leaves the existing alarm exactly where it is.
    /// Arming a *different* id for the same session cancels that session's old
    /// alarm first, because the row it belonged to is no longer the row on
    /// screen. Other sessions' alarms are untouched either way.
    func arm(
        sessionID: String,
        messageID: String,
        after: Duration,
        fire: @escaping @Sendable () async -> Void
    ) {
        guard alarms[sessionID]?.messageID != messageID else { return }
        alarms[sessionID]?.task.cancel()
        let clock = self.clock
        alarms[sessionID] = Alarm(
            messageID: messageID,
            task: Task { [weak self] in
                try? await clock.sleep(for: after)
                guard !Task.isCancelled else { return }
                await self?.clear(sessionID: sessionID, messageID: messageID)
                await fire()
            })
    }

    /// Cancels whatever is armed **for this session only**. Called on every
    /// publish that does not produce a completed row for it — the row was
    /// confirmed, aborted, superseded or switched off. A publish for one
    /// session must never disturb another's alarm, which is the whole reason
    /// this takes a session id.
    func disarm(sessionID: String) {
        alarms.removeValue(forKey: sessionID)?.task.cancel()
    }

    /// Cancels every alarm this timer holds.
    ///
    /// For tests, and for a caller that really is tearing down *everything*
    /// this timer serves. **Not** for a pane's own teardown: because the
    /// closure carrying this instance sits in the scheduler's single app-wide
    /// slot, the table can hold alarms for sessions other panes are showing,
    /// and cancelling one of those strands its provisional row on screen —
    /// the 60-second rule is announced by nothing, so nothing re-arms it. A
    /// pane leaving calls ``disarm(sessionID:)`` for its own session instead.
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
    /// already replaced it for that session.
    private func clear(sessionID: String, messageID: String) {
        guard alarms[sessionID]?.messageID == messageID else { return }
        alarms.removeValue(forKey: sessionID)
    }
}
