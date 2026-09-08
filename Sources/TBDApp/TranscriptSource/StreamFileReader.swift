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
    /// When the reader last saw a line for this message.
    ///
    /// The reader's clock, not the proxy's, and the same caller-stability rule
    /// as `.complete(at:)`: it moves only when a line actually arrives, so the
    /// deadline a silent `.streaming` row retires on does not slide forward on
    /// every poll. `StreamFileReader.fold` stamps it with the `now` it is
    /// handed and `TranscriptSource` is what holds it still.
    let lastLineAt: Date
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
    /// deadline forward on every poll and the row would never retire. The same
    /// applies to `lastLineAt`, which this call stamps with `now` and which the
    /// ten-minute silent-stream rule measures from.
    static func fold(lines: [ModelProxyStreamLine], now: Date) -> ProvisionalMessage? {
        guard let chosen = select(from: accumulate(lines)) else { return nil }
        return ProvisionalMessage(
            messageID: chosen.messageID, text: chosen.text, phase: chosen.phase(now: now),
            lastLineAt: now)
    }

    /// The id of the most recent message in these lines by the same ranking
    /// `fold` uses — the order the message's first line appears — or nil when
    /// there are no lines.
    ///
    /// Exists so callers that must reason about *which* message is the current
    /// one — the retained-line cap, which may never evict it — rank by the same
    /// rule the fold does instead of approximating it with the owner of the
    /// last line. The two answers part company exactly when messages
    /// interleave, which is the case the position ranking was written for: an
    /// older message that keeps appending after a newer one has started owns
    /// the last line while the newer one is the current turn.
    static func mostRecentMessageID(in lines: [ModelProxyStreamLine]) -> String? {
        mostRecent(accumulate(lines))?.messageID
    }

    /// Groups the lines by message id, recording each message's rank by where
    /// its first line appears.
    private static func accumulate(_ lines: [ModelProxyStreamLine]) -> [Accumulator] {
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
                accumulators[id]?.terminal = .stopped
            case let .aborted(_, reason):
                accumulators[id]?.terminal = .aborted(reason: reason)
            }
        }
        return Array(accumulators.values)
    }

    /// The one message worth rendering: the most recent with text, else the
    /// most recently started.
    private static func select(from candidates: [Accumulator]) -> Accumulator? {
        mostRecent(candidates.filter { !$0.text.isEmpty })
            ?? mostRecent(candidates.filter(\.hasStart))
    }

    /// The ranking itself, in one place: latest first line wins. Every notion
    /// of "most recent" in this file and in the retained-line cap goes through
    /// here, so none of them can drift apart.
    private static func mostRecent(_ candidates: [Accumulator]) -> Accumulator? {
        candidates.max { $0.position < $1.position }
    }

    /// What one message id has accumulated so far.
    private struct Accumulator {
        /// How a message ended, if it has. Dateless on purpose: `.complete`
        /// carries the instant the *reader* saw the stop, which is the
        /// caller's `now` and not a property of the lines.
        enum Terminal {
            case stopped
            case aborted(reason: String)
        }

        let messageID: String
        /// Rank of this message's first line in the file, so "most recent"
        /// needs no timestamps.
        let position: Int
        var deltasByBlock: [Int: [String]] = [:]
        /// The last terminal line wins: `stop` and `aborted` each overwrite
        /// whatever was here, so a tee that gave up and then saw the real end
        /// reports the end.
        var terminal: Terminal?
        var hasStart = false

        /// Blocks in ascending index, deltas within a block in arrival order.
        var text: String {
            deltasByBlock.sorted { $0.key < $1.key }.flatMap { $0.value }.joined()
        }

        func phase(now: Date) -> ProvisionalMessage.Phase {
            switch terminal {
            case nil: return .streaming
            case .stopped?: return .complete(at: now)
            case let .aborted(reason)?: return .aborted(reason: reason)
            }
        }
    }
}
