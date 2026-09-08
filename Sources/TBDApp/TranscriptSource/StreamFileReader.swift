import Foundation
import TBDShared

/// The assistant message a pane renders from the proxy's stream file, before
/// the session's transcript JSONL has caught up.
///
/// It is provisional in the strict sense: everything here is superseded the
/// moment the same `messageID` shows up in the transcript, at which point the
/// row is retired and the real transcript item takes over.
struct ProvisionalMessage: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Lines are still arriving, or the message ended in a way nobody
        /// wrote down (a proxy killed mid-turn leaves exactly this).
        case streaming
        /// A `message_stop` was seen. `at` is when the *reader* first saw it,
        /// not the proxy's clock — see `StreamFileReader.fold`.
        case complete(at: Date)
        /// The stream ended without a `message_stop`.
        case aborted(reason: String)
    }

    let messageID: String
    /// The message's text blocks concatenated in ascending block index.
    let text: String
    let phase: Phase
}

/// Folds the tagged lines of one terminal's stream file into the single
/// message worth rendering.
///
/// Pure and I/O-free: the caller owns the file, the tailing, and the clock.
struct StreamFileReader: Sendable {

    /// Folds the lines seen so far into the message to render, or nil when
    /// there is nothing worth showing yet.
    ///
    /// **Which message.** Lines of two messages interleave in the file when two
    /// parent requests are in flight against one route, so the fold groups by
    /// message id and then picks the most recent message that has text. "Most
    /// recent" is by position in the file — the order the message's first line
    /// appears — not by the `at` of its `start`, because file order is what the
    /// tee actually controls. When no message has text yet, the most recently
    /// started one is returned with empty text, so a pane can show that a turn
    /// has begun. When no message has either text or a `start`, the result is
    /// nil: there is nothing a reader could render.
    ///
    /// **Torn heads.** A `text` line whose message has no `start` still counts,
    /// keyed by the id the line itself carries. Truncation happens only when
    /// nothing is in flight, but a reader resuming mid-file can still see a
    /// head whose `start` it never read, and dropping that message would blank
    /// a pane that has text to show.
    ///
    /// **`now` is the caller's to keep stable.** `.complete(at:)` records the
    /// `now` handed to this call, and the 60-second unconfirmed rule measures
    /// from when the reader *first saw* the stop. So a caller that has already
    /// observed a stop must pass back the instant it recorded then, not a fresh
    /// `Date()` — folding the same lines with a moving `now` would push the
    /// deadline forward on every poll and the row would never retire.
    static func fold(lines: [ModelProxyStreamLine], now: Date) -> ProvisionalMessage? {
        var accumulators: [String: Accumulator] = [:]
        var nextPosition = 0

        for line in lines {
            let id = line.message
            if accumulators[id] == nil {
                accumulators[id] = Accumulator(messageID: id, position: nextPosition)
                nextPosition += 1
            }
            switch line {
            case .start:
                accumulators[id]?.hasStart = true
            case .block:
                // A block with no deltas contributes no text and no ordering
                // of its own — the `text` lines carry their own index.
                break
            case let .text(_, index, text):
                accumulators[id]?.deltasByBlock[index, default: []].append(text)
            case .stop:
                accumulators[id]?.phase = .complete(at: now)
            case let .aborted(_, reason):
                accumulators[id]?.phase = .aborted(reason: reason)
            }
        }

        let candidates = Array(accumulators.values)
        let mostRecentWithText = candidates
            .filter { !$0.text.isEmpty }
            .max { $0.position < $1.position }
        let mostRecentStarted = candidates
            .filter { $0.hasStart }
            .max { $0.position < $1.position }
        guard let chosen = mostRecentWithText ?? mostRecentStarted else { return nil }
        return ProvisionalMessage(messageID: chosen.messageID, text: chosen.text, phase: chosen.phase)
    }

    /// What one message id has accumulated so far.
    private struct Accumulator {
        let messageID: String
        /// Rank of this message's first line in the file, so "most recent"
        /// needs no timestamps.
        let position: Int
        var deltasByBlock: [Int: [String]] = [:]
        /// The last terminal line wins: `stop` and `aborted` each overwrite
        /// whatever was here, so a tee that gave up and then saw the real end
        /// reports the end.
        var phase: ProvisionalMessage.Phase = .streaming
        var hasStart = false

        /// Blocks in ascending index, deltas within a block in arrival order.
        var text: String {
            deltasByBlock.sorted { $0.key < $1.key }.flatMap { $0.value }.joined()
        }
    }
}
