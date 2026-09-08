import Foundation
import TBDShared

/// Appends the model-proxy stream's in-flight assistant message to a
/// freshly-read transcript as one **provisional row**, or leaves the transcript
/// alone when that row has been retired.
///
/// Pure and total: same inputs, same output, no I/O and no clock of its own.
/// The pane owns the reads (`TranscriptSource.provisional`,
/// `TranscriptSource.hasAssistantMessage`), the merge that runs before this
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
/// **Retirement.** Four of the five rules are announced by something the pane
/// already watches. Confirmation arrives with a transcript read, an abort and a
/// newer `start` (which `StreamFileReader.fold` resolves inside the fold, not
/// here) arrive with a stream-file change, and the flag going off restarts the
/// pane's loop. The fifth — a completed message nobody ever confirms — is
/// announced by nothing at all, which is why ``ProvisionalRetireTimer`` exists.
enum ProvisionalRowComposer {

    /// How long a *completed* stream message may stay unconfirmed before its
    /// row is withdrawn.
    ///
    /// This is the backstop for a turn the transcript will never mention: a
    /// side request the tee filter did not recognise, or a proxy that wrote a
    /// `message_stop` for a request Claude Code never wrote to its JSONL.
    /// Without it such a row would sit at the bottom of the pane forever.
    static let unconfirmedRetireAfter: Duration = .seconds(60)

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
    ///   - confirmed: whether the session's own transcript has caught up with a
    ///     message id. A closure rather than a set so the caller decides how
    ///     many ids it is worth asking about; today it asks about exactly one.
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

        switch provisional.phase {
        case .aborted:
            return items
        case .complete(let at):
            // Strictly less than, so the boundary tick retires rather than
            // composing a row whose remaining delay is zero. A zero-delay
            // alarm fires the moment it is armed, and the re-publish it runs
            // would compose the same row and arm the same zero again — a spin
            // under a `now` that is frozen or has stepped backwards. Keeping
            // the row only while the deadline is genuinely in the future makes
            // "compose keeps it" and "``retireDelay`` has a deadline" the same
            // condition.
            guard now.timeIntervalSince(at) < retireAfterSeconds else { return items }
        case .streaming:
            break
        }

        return items + [.assistantText(
            id: idPrefix + provisional.messageID,
            text: provisional.text,
            timestamp: nil,
            usage: nil)]
    }

    /// How long from `now` until a row composed for `phase` would retire on the
    /// unconfirmed-completion rule, or nil when no such deadline applies.
    ///
    /// Only `.complete` has one. `.streaming` has not stopped yet, and
    /// `.aborted` was already withdrawn by ``compose``. A deadline that has
    /// arrived or passed is nil rather than zero: ``compose`` has already
    /// retired that row, so there is nothing left to wake up for, and arming a
    /// zero-length sleep would fire instantly into a re-publish that composed
    /// the same row and armed the same zero again.
    static func retireDelay(phase: ProvisionalMessage.Phase, now: Date) -> Duration? {
        guard case .complete(let at) = phase else { return nil }
        let remaining = retireAfterSeconds - now.timeIntervalSince(at)
        guard remaining > 0 else { return nil }
        return .seconds(remaining)
    }

    /// ``unconfirmedRetireAfter`` as a `TimeInterval`, so the rule is stated
    /// once as a `Duration` (which is what the timer sleeps on) and compared
    /// against `Date` arithmetic here without a second literal.
    private static var retireAfterSeconds: TimeInterval {
        let components = unconfirmedRetireAfter.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
