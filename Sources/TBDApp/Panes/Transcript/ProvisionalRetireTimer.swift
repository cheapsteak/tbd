import Foundation

/// The one-shot alarm behind ``ProvisionalRowComposer/unconfirmedRetireAfter``.
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
/// An actor rather than a `@MainActor` type because the pane's on-change
/// handler is `@Sendable` and runs off the main actor; only the store write at
/// the end of a publish needs main.
actor ProvisionalRetireTimer {

    private let clock: any Clock<Duration>

    /// The message id the pending alarm belongs to, or nil when nothing is
    /// armed. Keyed by message id, not by deadline, so a poll every 100 ms
    /// re-arming for the same message is a no-op rather than a deadline that
    /// keeps sliding forward — the same reason `TranscriptSource` records the
    /// completion instant once.
    private var armedMessageID: String?
    private var pending: Task<Void, Never>?

    /// Existential `Clock`, last parameter, defaulted — the repo's clock seam.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Arms a single alarm for `messageID`, firing `after` from now.
    ///
    /// Idempotent per message id: re-arming for the id already armed leaves the
    /// existing alarm exactly where it is. Arming for a *different* id cancels
    /// the old alarm first, because the row it belonged to is no longer the row
    /// on screen.
    func arm(messageID: String, after: Duration, fire: @escaping @Sendable () async -> Void) {
        guard armedMessageID != messageID else { return }
        pending?.cancel()
        armedMessageID = messageID
        let clock = self.clock
        pending = Task { [weak self] in
            try? await clock.sleep(for: after)
            guard !Task.isCancelled else { return }
            await self?.clear(messageID)
            await fire()
        }
    }

    /// Cancels whatever is armed. Called on every publish that does *not*
    /// produce a completed row — the row was confirmed, aborted, superseded or
    /// switched off — and once more when the pane's loop ends, so a torn-down
    /// pane leaves no sleeping task behind.
    func disarm() {
        pending?.cancel()
        pending = nil
        armedMessageID = nil
    }

    /// The message id currently armed, or nil. Read-only, for tests — the same
    /// shape as `TranscriptPollScheduler`'s test accessors.
    var armedMessage: String? { armedMessageID }

    /// Clears the record of an alarm that has just fired, unless a later `arm`
    /// already replaced it.
    private func clear(_ messageID: String) {
        guard armedMessageID == messageID else { return }
        pending = nil
        armedMessageID = nil
    }
}
