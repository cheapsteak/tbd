import Foundation
import TBDShared

/// Appends the model-proxy stream's in-flight assistant message to a
/// freshly-read transcript as one **provisional row**, or leaves the transcript
/// alone when that row has been retired.
///
/// Pure and total: same inputs, same output, no I/O and no clock of its own.
/// The pane owns the reads (`TranscriptSource.provisional`,
/// `TranscriptSource.hasAssistantText`), the merge that runs before this
/// (`AskUserQuestionMerger`), and `now`.
///
/// **Order.** The row is appended last, after the JSONL items and after the
/// pending `AskUserQuestion` captures the merger synthesises, because it is the
/// newest thing in the session by construction: the JSONL has not caught up
/// with it yet, and a pending question was captured before the answer that is
/// streaming now.
///
/// **Identity.** The row's id is the API message id behind
/// ``idPrefix``, which does three things at once: it cannot collide with a
/// JSONL item id, it keeps the row's identity stable while its text grows (so
/// `TranscriptStreamPlan` sees `.updateLast` rather than a rebuild), and it is
/// what marks the row provisional downstream — `transcriptRenderNodes(from:)`
/// reads the prefix, nothing else has to be threaded through.
///
/// **Retirement.** Six rules take the row down, and every one of them is
/// listed here:
///
/// 1. **Confirmed** — the session's own JSONL holds the line carrying this
///    message's text, so the settled row replaces the provisional one.
///    Deliberately the text-bearing line and not merely the message id: Claude
///    Code writes one line per content block under a shared id, and they land
///    at different times, so a message opening with a `thinking` block would
///    otherwise retire its row while its text was still streaming and leave
///    nothing in its place. A turn that never writes text at all — one that
///    only calls tools — is confirmed by nothing and leaves by rule 5.
/// 2. **Aborted** — the stream file records an `aborted` line for the message.
/// 3. **Superseded** — a newer message's lines make it the one the fold
///    renders, so the older row is no longer the row on screen.
/// 4. **Streaming switched off** — the resolved streaming flag is off, whatever
///    the stream file holds.
/// 5. **Completed but unconfirmed for 60 s** — ``unconfirmedRetireAfter``,
///    measured from the stop the reader saw.
/// 6. **Streaming but silent for 600 s** — ``silentStreamRetireAfter``,
///    measured from the last line the reader saw, and equal to the proxy's own
///    drain cap.
///
/// The first four are announced by something the pane already watches:
/// confirmation arrives with a transcript read, an abort and a newer `start`
/// (which `StreamFileReader.fold` resolves inside the fold, not here) arrive
/// with a stream-file change, and the flag going off restarts the pane's loop.
/// The last two — a completed message nobody ever confirms, and a stream that
/// simply stops arriving — are announced by nothing at all, which is why
/// ``ProvisionalRetireTimer`` exists. Both are deadlines; they differ only in
/// what they measure from and how long they allow.
enum ProvisionalRowComposer {

    /// How long a *completed* stream message may stay unconfirmed before its
    /// row is withdrawn, measured from when the reader first saw the stop.
    ///
    /// This is the backstop for a turn the transcript will never confirm: a
    /// side request the tee filter did not recognise, a proxy that wrote a
    /// `message_stop` for a request Claude Code never wrote to its JSONL, or a
    /// turn that ends without a text block at all — one that only calls tools —
    /// whose JSONL lines carry the message id but never its text. Without it
    /// such a row would sit at the bottom of the pane forever.
    static let unconfirmedRetireAfter: Duration = .seconds(60)

    /// How long a *streaming* message may go without a new line before its row
    /// is withdrawn, measured from the last line the reader saw.
    ///
    /// A message reaches a terminal phase only when a `stop` or `aborted` line
    /// is written and decoded. A proxy killed mid-turn writes neither, so the
    /// fold reports `.streaming` forever and the transcript — which never saw
    /// that request finish either — will not confirm it. Without a deadline of
    /// its own that row stays on screen until the pane closes.
    ///
    /// Ten minutes, not sixty seconds, because silence is normal here in a way
    /// it is not after a stop: the tee records text deltas, and a turn
    /// streaming a large tool-input block emits none of them for minutes while
    /// the request is perfectly healthy. The proxy's own drain cap is the
    /// longest a legitimate stream can still be in flight, so a stream quiet
    /// for longer than that is one nothing is coming back for. It *is* that
    /// cap — ``TBDShared/ModelProxyLimits/drainCap``, the same constant
    /// `TBDModelProxy`'s retire drain sleeps on — rather than a second literal
    /// that happens to agree with it.
    static let silentStreamRetireAfter: Duration = ModelProxyLimits.drainCap

    /// Prefix on the provisional row's item id. Deliberately a prefix of the
    /// real message id rather than an opaque token, so the row's identity is
    /// stable across ticks and a reader looking at a log can see which message
    /// it belonged to.
    static let idPrefix = "stream:"

    /// Whether a transcript item id belongs to a provisional row.
    static func isProvisional(itemID: String) -> Bool {
        itemID.hasPrefix(idPrefix)
    }

    /// `items` with any provisional row removed.
    ///
    /// The inverse of ``compose``, for the one reader that shares the store
    /// with the live pane but must never show the row: Session History.
    static func settledOnly(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { !isProvisional(itemID: $0.id) }
    }

    /// Returns `items` with the provisional row appended, or `items` unchanged
    /// when the row is retired.
    ///
    /// - Parameters:
    ///   - items: the transcript as it stands — JSONL items with pending
    ///     `AskUserQuestion` captures already merged in.
    ///   - provisional: what the stream file currently folds to, or nil when
    ///     nothing has been tailed for this session.
    ///   - confirmed: whether the session's own transcript holds the
    ///     text-bearing line for a message id, not merely "a line with this id
    ///     landed" — `TranscriptSource.hasAssistantText`. A closure rather than
    ///     a set so the caller decides how many ids it is worth asking about;
    ///     today it asks about exactly one.
    ///   - now: the instant the retire deadline is measured against. The
    ///     caller's to keep stable across one publish.
    ///   - streamingEnabled: the resolved streaming flag. Off means no row,
    ///     whatever the stream file holds.
    static func compose(
        items: [TranscriptItem],
        provisional: ProvisionalMessage?,
        confirmed: (String) -> Bool,
        now: Date,
        streamingEnabled: Bool
    ) -> [TranscriptItem] {
        guard streamingEnabled, let provisional else { return items }
        guard !confirmed(provisional.messageID) else { return items }
        // Nil is `.aborted`, which is withdrawn outright. Otherwise the row
        // survives strictly *before* its deadline, so the boundary tick
        // retires rather than composing a row whose remaining delay is zero. A
        // zero-delay alarm fires the moment it is armed, and the re-publish it
        // runs would compose the same row and arm the same zero again — a spin
        // under a `now` that is frozen or has stepped backwards. Keeping the
        // row only while the deadline is genuinely in the future makes
        // "compose keeps it" and "``retireDelay`` has a deadline" the same
        // condition.
        guard let deadline = retireDeadline(for: provisional), now < deadline else {
            return items
        }

        return items + [.assistantText(
            id: idPrefix + provisional.messageID,
            text: provisional.text,
            timestamp: nil,
            usage: nil)]
    }

    /// The instant a composed row for `provisional` retires on its own, or nil
    /// when it is already withdrawn.
    ///
    /// `.complete` retires ``unconfirmedRetireAfter`` from the stop the reader
    /// saw; `.streaming` retires ``silentStreamRetireAfter`` from the last line
    /// it saw; `.aborted` has no deadline because ``compose`` never gives it a
    /// row. Both live deadlines move only when their basis does, which is what
    /// makes this safe to call on every poll: `ProvisionalMessage` carries
    /// instants `TranscriptSource` holds still, never a fresh `Date()`.
    ///
    /// Also the alarm's identity — see ``ProvisionalRetireTimer/arm``. A line
    /// arriving for a streaming message moves the deadline, and that is exactly
    /// when the pending alarm must be replaced rather than left alone.
    static func retireDeadline(for provisional: ProvisionalMessage) -> Date? {
        switch provisional.phase {
        case .aborted:
            return nil
        case .complete(let at):
            return at.addingTimeInterval(seconds(unconfirmedRetireAfter))
        case .streaming:
            return provisional.lastLineAt.addingTimeInterval(seconds(silentStreamRetireAfter))
        }
    }

    /// How long from `now` until ``retireDeadline(for:)`` arrives, or nil when
    /// there is no deadline or it has already passed.
    ///
    /// A deadline that has arrived or passed is nil rather than zero:
    /// ``compose`` has already retired that row, so there is nothing left to
    /// wake up for, and arming a zero-length sleep would fire instantly into a
    /// re-publish that composed the same row and armed the same zero again.
    static func retireDelay(for provisional: ProvisionalMessage, now: Date) -> Duration? {
        guard let deadline = retireDeadline(for: provisional) else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return .seconds(remaining)
    }

    /// A `Duration` as a `TimeInterval`, so each rule is stated once as the
    /// `Duration` the timer sleeps on and compared against `Date` arithmetic
    /// here without a second literal.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
